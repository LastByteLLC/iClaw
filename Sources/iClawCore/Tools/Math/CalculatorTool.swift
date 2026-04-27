import Foundation
import AppIntents
import ObjCExceptionCatcher

/// Closure type for injecting a test LLM responder into the CalculatorTool.
public typealias CalculatorLLMResponder = SimpleLLMResponder

/// Calculator tool for basic math operations.
/// Implements CoreTool protocol and exposes an AppIntent for system-wide access.
///
/// Uses a two-stage approach:
/// 1. **Sanitizer** — strips natural language, normalizes operators, handles percent/sqrt/squared
/// 2. **LLM normalization fallback** — if the sanitizer rejects the input, asks the LLM to
///    rewrite it as a pure math expression, then evaluates that deterministically.
///    The LLM never computes the answer — it only translates language to math.
public struct CalculatorTool: CoreTool, Sendable {
    public let name = "Calculator"
    public let schema = "Perform math calculations arithmetic: addition subtraction multiplication division times plus minus divided multiply subtract percent percentage tip discount square root sqrt exponent power factorial logarithm logarithms sine cosine tangent trigonometry integral derivative geometry hypotenuse circle triangle area volume GCD LCM prime combinations permutations compound interest statistics mean median average"
    public let isInternal = false
    public let category = CategoryEnum.offline

    private let llmResponder: CalculatorLLMResponder?
    private let llmAdapter: LLMAdapter

    // MARK: - Cached Date Formatters

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    public init(llmResponder: CalculatorLLMResponder? = nil, llmAdapter: LLMAdapter = .shared) {
        self.llmResponder = llmResponder
        self.llmAdapter = llmAdapter
    }

    /// Characters allowed in a math expression for NSExpression.
    private static let allowedCharacters = CharacterSet(charactersIn: "0123456789+-*/%().^ eE")
        .union(.whitespaces)

    /// Structural math-symbol set for input-evidence checks.
    /// Includes ASCII operators plus common Unicode math operators used in
    /// any language. Kept separate from `allowedCharacters` because the
    /// latter is for NSExpression input; this is for detection.
    private static let mathSymbolSet: Set<Character> = [
        "+", "-", "*", "/", "^", "%", "=",
        "×", "÷", "√", "∛", "∜", "π", "∑", "∫", "≈"
    ]

    /// Returns true if the input contains at least one numeral (any script)
    /// or math symbol. Used to gate LLM-based math normalization — without
    /// this, the LLM will happily fabricate calculations for non-math inputs
    /// like "by how much?", "explain that", or ambiguous follow-ups.
    /// Also accepts word-number/word-operator inputs like "two plus three"
    /// which are legitimate math expressions without digits or symbols.
    static func hasNumericEvidence(_ input: String) -> Bool {
        for ch in input {
            if ch.isNumber { return true }
            if Self.mathSymbolSet.contains(ch) { return true }
        }
        let tokens = input.lowercased().wordTokenSet
        if !tokens.isDisjoint(with: Self.wordNumberTokens) { return true }
        if !tokens.isDisjoint(with: Self.wordOperatorTokens) { return true }
        return false
    }

    private static let wordNumberTokens: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "dozen", "half", "quarter"
    ]

    private static let wordOperatorTokens: Set<String> = [
        "plus", "minus", "times", "divided", "over", "squared", "cubed", "percent"
    ]

    // MARK: - Explain Pattern

    /// Detects explain-mode requests from the calculator widget's "Explain" button.
    private static let explainPattern = try! NSRegularExpression(
        pattern: #"^\[Replying to: \"(.+?)\" → \"(.+?)\"\]\s*Explain"#,
        options: .caseInsensitive
    )

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            // Check for explain mode (from widget "Explain" button)
            let nsInput = input as NSString
            if let match = Self.explainPattern.firstMatch(in: input, range: NSRange(location: 0, length: nsInput.length)) {
                let expression = nsInput.substring(with: match.range(at: 1))
                let result = nsInput.substring(with: match.range(at: 2))
                return await explainCalculation(expression: expression, result: result)
            }

            // Date arithmetic: intercept before math sanitization
            if let dateResult = Self.tryDateArithmetic(input: input) {
                return dateResult
            }

            // Stage 0: Advanced-math reducers (GCD, LCM, prime, nCr, mean,
            // median, stdev, compound interest, triangle/circle area,
            // hypotenuse, base conversion, series sum). NSExpression can't
            // evaluate these; the Swift reducers return exact values.
            if let advanced = AdvancedMathReducers.reduce(input) {
                return ToolIO(
                    text: advanced.display,
                    status: .ok,
                    outputWidget: "MathWidget",
                    widgetData: CalculationWidgetData(
                        expression: input,
                        result: advanced.display,
                        unit: nil, symbol: nil, label: nil,
                        supplementary: []
                    ),
                    isVerifiedData: true,
                    emitDirectly: true
                )
            }

            // Stage 1: Try sanitizer
            var sanitized = Self.sanitize(input)

            // Stage 2: If sanitizer rejects, ask LLM to normalize — but
            // only if the input carries at least one numeral or math symbol.
            // Inputs like "by how much?" or "explain that" have no numeric
            // anchor; the LLM will hallucinate a calculation (e.g. a full
            // mortgage amortization) if we invite it to. Fail closed by
            // returning empty/error and let the engine fall back to
            // conversational. Unicode-aware: `Character.isNumber` matches
            // digits in any script, and the math-symbol set is language-
            // neutral by construction.
            var usedLLMNormalization = false
            if sanitized.isEmpty {
                guard Self.hasNumericEvidence(input) else {
                    return ToolIO(
                        text: "",
                        status: .error
                    )
                }
                if let llmResult = await llmNormalize(input: input, detectedLanguage: entities?.detectedLanguage) {
                    // Check if LLM returned loan parameters (JSON with principal/rate/years)
                    if let loanResult = Self.parseLoanJSON(llmResult, originalInput: input) {
                        return loanResult
                    }
                    let reSanitized = Self.sanitize(llmResult)
                    if !reSanitized.isEmpty {
                        sanitized = reSanitized
                        usedLLMNormalization = true
                    }
                }
            }

            guard !sanitized.isEmpty else {
                return ToolIO(
                    text: "Couldn't parse a math expression from: \(input)",
                    status: .error
                )
            }

            var result = Self.evaluate(sanitized, originalInput: input)

            // If evaluation failed (e.g., "e^2" → crash caught by ObjCTryCatch),
            // retry via LLM normalization. The LLM converts "e^2" → "2.71828**2".
            if result.status == .error && !usedLLMNormalization {
                if let llmResult = await llmNormalize(input: input, detectedLanguage: entities?.detectedLanguage) {
                    if let loanResult = Self.parseLoanJSON(llmResult, originalInput: input) {
                        return loanResult
                    }
                    let reSanitized = Self.sanitize(llmResult)
                    if !reSanitized.isEmpty {
                        let retryResult = Self.evaluate(reSanitized, originalInput: input)
                        if retryResult.status == .ok {
                            result = retryResult
                        }
                    }
                }
            }

            // Mark as partial if LLM normalization was needed but produced a valid result
            if usedLLMNormalization && result.status == .ok {
                result = ToolIO(
                    text: result.text,
                    attachments: result.attachments,
                    status: .partial,
                    outputWidget: result.outputWidget,
                    widgetData: result.widgetData,
                    isVerifiedData: result.isVerifiedData
                )
            }
            return result
        }
    }

    /// Pre-validates an expression string for structural correctness before passing to NSExpression.
    /// NSExpression(format:) throws ObjC NSInvalidArgumentException on malformed input,
    /// which Swift's do/catch cannot intercept — so we must reject bad expressions here.
    private static func isValidForNSExpression(_ expr: String) -> Bool {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Reject comparison operators (not valid in NSExpression arithmetic)
        if trimmed.contains("==") || trimmed.contains("!=")
            || trimmed.contains("<=") || trimmed.contains(">=")
            || trimmed.contains("<") || trimmed.contains(">") { return false }

        // Reject trailing operators
        if let last = trimmed.last, "+-*/%^".contains(last) { return false }

        // Reject leading operators (except unary minus)
        if let first = trimmed.first, "+*/%^".contains(first) { return false }

        // Check balanced parentheses
        var depth = 0
        for ch in trimmed {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        if depth != 0 { return false }

        // Reject empty parentheses
        if trimmed.contains("()") { return false }

        return true
    }

    /// Evaluates a sanitized expression string via NSExpression.
    private static func evaluate(_ expr: String, originalInput: String) -> ToolIO {
        guard isValidForNSExpression(expr) else {
            return ToolIO(
                text: "Invalid math expression: \(originalInput)",
                status: .error
            )
        }

        // NSExpression(format:) throws ObjC NSException on malformed input, which
        // Swift's do/catch cannot intercept. Use ObjCTryCatch as a safety net.
        var expression: NSExpression?
        var objcError: NSError?
        let parsed = ObjCTryCatch({
            expression = NSExpression(format: expr)
        }, &objcError)

        guard parsed, let expression else {
            let reason = objcError?.localizedDescription ?? "Parse failed"
            return ToolIO(
                text: "Invalid math expression: \(originalInput). \(reason)",
                status: .error
            )
        }

        // NSExpression.expressionValue can also throw ObjC exceptions during
        // EVALUATION (not just parsing) — e.g., "e^2" parses fine but crashes
        // when evaluating because 'e' resolves to nil in a nil context.
        // Wrap in ObjCTryCatch to prevent the entire app from crashing.
        var evalResult: Any?
        var evalError: NSError?
        let evalSuccess = ObjCTryCatch({
            evalResult = expression.expressionValue(with: nil, context: nil)
        }, &evalError)

        if !evalSuccess || evalError != nil {
            // Evaluation crashed (e.g., variable like 'e' in expression).
            // Fall through to error handling below, which triggers LLM fallback.
            return ToolIO(
                text: "Math evaluation failed for '\(originalInput)'. The expression may contain unsupported variables or functions.",
                status: .error
            )
        }

        if var result = evalResult as? Double {
            // Apply post-evaluation rounding if requested
            let lowerInput = originalInput.lowercased()
            if lowerInput.contains("round to") || lowerInput.contains("nearest") {
                if lowerInput.contains("nearest dollar") || lowerInput.contains("nearest whole") {
                    result = Foundation.round(result)
                } else if lowerInput.contains("nearest cent") || lowerInput.contains("nearest penny") {
                    result = Foundation.round(result * 100) / 100
                } else if lowerInput.contains("nearest ten") {
                    result = Foundation.round(result / 10) * 10
                } else if lowerInput.contains("nearest hundred") {
                    result = Foundation.round(result / 100) * 100
                } else {
                    result = Foundation.round(result)
                }
            }
            let formatted = formatResult(result, input: originalInput)

            let widgetData = CalculationWidgetData(
                expression: originalInput,
                result: formatted.display,
                unit: formatted.unit,
                symbol: formatted.symbol,
                label: formatted.label
            )

            // Clean user-facing text: strip leading natural-language filler
            // ("what's", "calculate", etc.) and trailing punctuation so the
            // output reads as "437 * 29 = 12,673" not "What's 437 * 29? =
            // 12,673". Emits directly — the LLM finalizer adds nothing here
            // and only risks paraphrase drift (LaTeX thin-space for commas,
            // scientific notation, etc.).
            let displayExpr = Self.stripNaturalLanguageFluff(originalInput)
            let unitSuffix = formatted.unit.map { " \($0)" } ?? ""
            let symbolPrefix = formatted.symbol ?? ""
            let resultPiece = "\(symbolPrefix)\(formatted.display)\(unitSuffix)"
            let directText: String
            if displayExpr.isEmpty {
                directText = resultPiece
            } else {
                directText = "\(displayExpr) = \(resultPiece)"
            }
            return ToolIO(
                text: directText,
                status: .ok,
                outputWidget: "MathWidget",
                widgetData: widgetData,
                isVerifiedData: true,
                emitDirectly: true
            )
        } else {
            return ToolIO(
                text: "Invalid math expression: \(originalInput). Expression evaluation failed.",
                status: .error
            )
        }
    }

    // MARK: - Result Formatting

    private struct FormattedResult {
        let display: String
        let unit: String?
        let symbol: String?
        let label: String?
    }

    /// Multilingual financial keyword table loaded from
    /// `Resources/Config/CalculatorFinancialKeywords.json`.
    private static let financialKeywords: MultilingualKeywords? = MultilingualKeywords.load("CalculatorFinancialKeywords")

    /// Formats the numeric result with appropriate rounding, currency symbols, and units
    /// based on context clues in the original input.
    private static func formatResult(_ value: Double, input: String) -> FormattedResult {
        let lower = input.lowercased()

        // Currency detection — multilingual via CalculatorFinancialKeywords.
        // Currency-symbol shortcut covers $/€/£/¥/₩/R$ universally.
        let hasCurrencySymbol = lower.contains("$") || lower.contains("€")
            || lower.contains("£") || lower.contains("¥") || lower.contains("₩")
        let hasCurrencyKeyword: Bool = {
            guard let kw = financialKeywords else { return false }
            return kw.matches(intent: "currency_terms", in: input)
                || kw.matches(intent: "loan_terms", in: input)
                || kw.matches(intent: "tax_terms", in: input)
                || kw.matches(intent: "income_terms", in: input)
                || kw.matches(intent: "tip_terms", in: input)
        }()
        let hasCurrency = hasCurrencySymbol || hasCurrencyKeyword
        if hasCurrency {
            return FormattedResult(
                display: formatNumber(value, decimalPlaces: 2),
                unit: nil,
                symbol: "$",
                label: detectLabel(lower)
            )
        }

        // Percentage result
        let isPercentCalc = lower.contains("percent") || lower.contains("%")
        if isPercentCalc {
            // If the input is "X% of Y", the result is a plain number, not a percentage
            // But if it's "what percent", the result IS a percentage
            let isWhatPercent = lower.contains("what percent") || lower.contains("what %")
            if isWhatPercent {
                return FormattedResult(
                    display: formatNumber(value, decimalPlaces: 1),
                    unit: "%",
                    symbol: nil,
                    label: nil
                )
            }
        }

        // Integer result (no decimals needed)
        if value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15 {
            return FormattedResult(
                display: formatNumber(value, decimalPlaces: 0),
                unit: nil,
                symbol: nil,
                label: detectLabel(lower)
            )
        }

        // Default: round to reasonable precision
        let places = abs(value) < 1 ? 4 : (abs(value) < 100 ? 2 : 2)
        return FormattedResult(
            display: formatNumber(value, decimalPlaces: places),
            unit: nil,
            symbol: nil,
            label: detectLabel(lower)
        )
    }

    /// Formats a number with thousands separators and specified decimal places.
    private static func formatNumber(_ value: Double, decimalPlaces: Int) -> String {
        NumberFormatting.decimal(fractionDigits: decimalPlaces, grouping: true)
            .string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Detects a contextual label from the input (e.g., "Simple Interest", "Monthly Payment").
    private static func detectLabel(_ input: String) -> String? {
        if input.contains("interest") { return "Interest" }
        if input.contains("monthly") && input.contains("payment") { return "Monthly Payment" }
        if input.contains("tip") { return "Tip Amount" }
        if input.contains("tax") { return "Tax" }
        if input.contains("discount") { return "Discount" }
        if input.contains("profit") { return "Profit" }
        if input.contains("salary") || input.contains("income") { return "Income" }
        return nil
    }

    // MARK: - Explain Mode

    /// Uses the LLM to generate a step-by-step explanation of how a calculation was performed.
    /// The output may contain LaTeX notation which is rendered by LaTeXRenderer in the chat view.
    private func explainCalculation(expression: String, result: String) async -> ToolIO {
        let prompt = """
Explain this calculation step by step. Be concise.
Expression: \(expression)
Result: \(result)
Rules:
- Use numbered steps showing each operation with actual numbers
- Use LaTeX \\( \\) delimiters for mathematical expressions: \\(\\frac{a}{b}\\), \\(x^2\\), \\(\\sqrt{x}\\)
- For fractions, use \\(\\frac{numerator}{denominator}\\) notation
- For exponents, use \\(x^{n}\\) notation
- For loan formulas, show the full formula: \\(M = P \\cdot \\frac{r(1+r)^n}{(1+r)^n - 1}\\)
- Keep step descriptions in plain text, only wrap math in \\( \\)
- Output ONLY the numbered steps, nothing else
"""

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(prompt)
            } else {
                response = try await llmAdapter.generateText(prompt)
            }

            return ToolIO(
                text: "Explanation of \(expression) = \(result):\n\n\(response)",
                status: .ok
            )
        } catch {
            // Fallback: return a basic explanation without LLM
            return ToolIO(
                text: "Explanation: \(expression) = \(result). The on-device model couldn't generate a detailed explanation right now.",
                status: .ok
            )
        }
    }

    // MARK: - Loan / Amortization

    /// Tries to parse LLM output as loan JSON: {"principal":N,"rate":N,"years":N,"down_payment":N?}
    /// When `down_payment` is present it is subtracted from `principal` to yield the true loan amount.
    private static func parseLoanJSON(_ llmOutput: String, originalInput: String) -> ToolIO? {
        guard let data = llmOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPrincipal = (json["principal"] as? Double) ?? (json["principal"] as? Int).map(Double.init),
              let annualRate = (json["rate"] as? Double) ?? (json["rate"] as? Int).map(Double.init),
              let years = (json["years"] as? Int) ?? (json["years"] as? Double).map(Int.init),
              rawPrincipal > 0, annualRate > 0, years > 0 else {
            return nil
        }
        var downPayment = (json["down_payment"] as? Double) ?? (json["down_payment"] as? Int).map(Double.init) ?? 0
        // Safety net: if the user mentioned "X down" but the LLM missed it, parse from the original input.
        if downPayment == 0, let parsed = parseDownPayment(from: originalInput, principal: rawPrincipal) {
            downPayment = parsed
        }
        let loanAmount = max(rawPrincipal - downPayment, 0)
        guard loanAmount > 0 else { return nil }
        return computeLoan(principal: loanAmount, annualRate: annualRate, years: years, originalInput: originalInput)
    }

    /// Scans natural-language input for a down-payment amount ("200k down", "20% down", "$150,000 down").
    /// Returns the absolute dollar amount, or nil if none detected.
    private static func parseDownPayment(from input: String, principal: Double) -> Double? {
        let lower = input.lowercased()
        // Percent-down: "20% down" → principal * 0.20
        if let match = lower.range(of: #"(\d+(?:\.\d+)?)\s*%\s*down"#, options: .regularExpression) {
            let fragment = String(lower[match])
            if let pct = fragment.split(separator: "%").first,
               let value = Double(pct.trimmingCharacters(in: .whitespaces)), value > 0, value < 100 {
                return principal * (value / 100.0)
            }
        }
        // Absolute-down with k/m suffix or bare: "200k down", "$150,000 down", "150000 down"
        if let match = lower.range(of: #"\$?(\d+(?:[,.]?\d+)*)\s*([km])?\s*down"#, options: .regularExpression) {
            let fragment = String(lower[match])
            let digits = fragment
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "down", with: "")
                .replacingOccurrences(of: "k", with: "")
                .replacingOccurrences(of: "m", with: "")
            if var value = Double(digits), value > 0 {
                if fragment.contains("k") { value *= 1_000 }
                if fragment.contains("m") { value *= 1_000_000 }
                return value
            }
        }
        return nil
    }

    /// Computes monthly payment + amortization table for loan requests.
    static func computeLoan(principal: Double, annualRate: Double, years: Int, originalInput: String) -> ToolIO {

        let monthlyRate = annualRate / 100.0 / 12.0
        let totalPayments = years * 12

        // Standard amortization formula: M = P * [r(1+r)^n] / [(1+r)^n - 1]
        let factor = pow(1 + monthlyRate, Double(totalPayments))
        let monthlyPayment = principal * (monthlyRate * factor) / (factor - 1)
        let totalPaid = monthlyPayment * Double(totalPayments)
        let totalInterest = totalPaid - principal

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true

        let fmtPayment = formatter.string(from: NSNumber(value: monthlyPayment)) ?? "\(monthlyPayment)"
        let fmtTotalPaid = formatter.string(from: NSNumber(value: totalPaid)) ?? "\(totalPaid)"
        let fmtTotalInterest = formatter.string(from: NSNumber(value: totalInterest)) ?? "\(totalInterest)"
        let fmtPrincipal = formatter.string(from: NSNumber(value: principal)) ?? "\(principal)"

        // Build amortization table (first 12 months + last month)
        var rows: [[String]] = []
        var balance = principal
        for month in 1...totalPayments {
            let interestPortion = balance * monthlyRate
            let principalPortion = monthlyPayment - interestPortion
            balance -= principalPortion

            if month <= 12 || month == totalPayments {
                rows.append([
                    "\(month)",
                    "$\(formatter.string(from: NSNumber(value: principalPortion)) ?? "")",
                    "$\(formatter.string(from: NSNumber(value: interestPortion)) ?? "")",
                    "$\(formatter.string(from: NSNumber(value: max(balance, 0))) ?? "")"
                ])
            } else if month == 13 {
                rows.append(["...", "...", "...", "..."])
            }
        }

        let widgetData = CalculationWidgetData(
            expression: originalInput,
            result: fmtPayment,
            unit: "/mo",
            symbol: "$",
            label: "Monthly Payment",
            supplementary: [
                CalculationWidgetData.SupplementaryResult(label: "Principal", value: "$\(fmtPrincipal)"),
                CalculationWidgetData.SupplementaryResult(label: "Total Interest", value: "$\(fmtTotalInterest)"),
                CalculationWidgetData.SupplementaryResult(label: "Total Paid", value: "$\(fmtTotalPaid)")
            ],
            table: CalculationWidgetData.TableData(
                title: "Amortization Schedule",
                columns: ["Mo", "Principal", "Interest", "Balance"],
                rows: rows
            )
        )

        let text = "Monthly payment on $\(fmtPrincipal) at \(annualRate)% for \(years) years: $\(fmtPayment)/mo. Total interest: $\(fmtTotalInterest). Total paid: $\(fmtTotalPaid)."

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "MathWidget",
            widgetData: widgetData
        )
    }

    // MARK: - LLM Normalization Fallback

    /// Asks the LLM to rewrite natural language as a pure math expression.
    /// The LLM does NOT compute the result — it only translates.
    /// For loan/amortization requests, returns JSON: {"principal":N,"rate":N,"years":N}
    private func llmNormalize(input: String, detectedLanguage: String? = nil) async -> String? {
        let langHint = detectedLanguage.map { "The input may be in \($0). " } ?? "The input may be in any language. "
        let prompt = """
\(langHint)Rewrite this as a math expression using ONLY numbers and operators (+, -, *, /, **, ()). \
Translate any natural language math words to their operator equivalents (e.g., fois/mal/por → *, \
plus/más/plus → +, moins/weniger/menos → -, divisé/geteilt/dividido → /). \
Output ONLY the expression, nothing else. Use ** for exponents, * for multiplication. \
Ignore any post-processing instructions like "round to nearest" — extract ONLY the core math.

If this is a loan/mortgage/amortization request, output JSON instead: {"principal":N,"rate":N,"years":N,"down_payment":N} \
where principal is the home/asset price OR the loan amount, rate is the annual interest rate (e.g. 6.5 for 6.5%), \
years is the term, and down_payment is the cash-down amount (0 if not mentioned). The engine subtracts \
down_payment from principal to compute the true loan amount, so when the user says "$600k house with $200k down" \
output principal=600000 AND down_payment=200000 (NOT principal=400000). If the user gives the loan amount directly, \
set down_payment=0. If years is not stated, default to 30.

Examples:
- "25% of 300" → (300 * 25 / 100)
- "42 fois 17" → 42 * 17
- "42 mal 17" → 42 * 17
- "100 dividido por 3" → 100 / 3
- "square root of 144" → 144 ** 0.5
- "area of circle radius 7" → 3.14159265 * 7 ** 2
- "volume of sphere radius 3" → (4.0 / 3.0) * 3.14159265 * 3 ** 3
- "hypotenuse of 5 and 12" → (5 ** 2 + 12 ** 2) ** 0.5
- "circumference radius 10" → 2 * 3.14159265 * 10
- "85000 salary after 24% tax monthly" → 85000 * (1 - 0.24) / 12
- "e^2" → 2.71828 ** 2
- "BMI for 175 lbs 5 foot 10" → 175 * 703 / (70 ** 2)
- "sin(45)" → 0.70710678
- "log base 2 of 1024" → 10
- "$200000 loan at 6.5% for 30 years" → {"principal":200000,"rate":6.5,"years":30,"down_payment":0}
- "monthly payment on a 600k house with 200k down and 6.05% interest" → {"principal":600000,"rate":6.05,"years":30,"down_payment":200000}
- "mortgage on $750k, 20% down, 7% for 15 years" → {"principal":750000,"rate":7,"years":15,"down_payment":150000}
- "what's 15% of 85 rounded to the nearest dollar" → (85 * 15 / 100)
- "factorial of 10" → 3628800
- "5!" → 120

Input: \(input)
Output:
"""

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(prompt)
            } else {
                // Expression normalization — greedy + 50-token cap.
                response = try await llmAdapter.generateText(prompt, profile: .normalization)
            }
            // Take only the first line, strip whitespace
            let normalized = response
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? nil : normalized
        } catch {
            return nil
        }
    }

    // MARK: - Date Arithmetic

    /// Detects and computes date arithmetic expressions.
    /// Handles: "how many days until X", "X days from now", "what day was X days ago",
    /// "how many days between X and Y", "what day of the week was DATE".
    /// Returns nil if the input is not a date arithmetic query.
    private static func tryDateArithmetic(input: String) -> ToolIO? {
        let lower = input.lowercased()
        let calendar = Calendar.current
        let now = Date()

        // Pattern 1: "how many days until <date>" / "days until <event>"
        if let result = matchDaysUntil(lower, calendar: calendar, now: now, original: input) {
            return result
        }

        // Pattern 2: "<N> days from now" / "what day is <N> days from now"
        if let result = matchDaysFromNow(lower, calendar: calendar, now: now) {
            return result
        }

        // Pattern 3: "<N> days ago" / "what day was <N> days ago"
        if let result = matchDaysAgo(lower, calendar: calendar, now: now) {
            return result
        }

        // Pattern 4: "how many days between <date> and <date>"
        if let result = matchDaysBetween(lower, calendar: calendar, original: input) {
            return result
        }

        // Pattern 5: "what day of the week was/is <date>"
        if let result = matchDayOfWeek(lower, calendar: calendar, original: input) {
            return result
        }

        return nil
    }

    /// "how many days until Christmas", "days until March 25", "how long until my birthday on June 10"
    private static func matchDaysUntil(_ lower: String, calendar: Calendar, now: Date, original: String) -> ToolIO? {
        let patterns = ["days until ", "how long until ", "how many days till ", "how many days until ", "countdown to "]
        for pattern in patterns {
            guard let range = lower.range(of: pattern) else { continue }
            let dateStr = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "?")))
            guard !dateStr.isEmpty, let targetDate = parseNaturalDate(dateStr, relativeTo: now) else { continue }

            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: targetDate)).day ?? 0

            let label: String
            if days == 0 {
                label = "That's today!"
            } else if days == 1 {
                label = "That's tomorrow — 1 day away."
            } else if days < 0 {
                label = "\(abs(days)) days ago (\(Self.longDateFormatter.string(from: targetDate)))."
            } else {
                label = "\(days) days from now (\(Self.longDateFormatter.string(from: targetDate)))."
            }

            let widgetData = CalculationWidgetData(
                expression: original,
                result: "\(abs(days))",
                unit: days == 1 ? " day" : " days",
                symbol: nil,
                label: days < 0 ? "Days Since" : "Days Until"
            )

            return ToolIO(
                text: label,
                status: .ok,
                outputWidget: "MathWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
        return nil
    }

    /// "30 days from now", "what day is 90 days from now"
    private static func matchDaysFromNow(_ lower: String, calendar: Calendar, now: Date) -> ToolIO? {
        let regex = try? NSRegularExpression(pattern: #"(\d+)\s*days?\s*from\s*(?:now|today)"#, options: .caseInsensitive)
        guard let match = regex?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let daysRange = Range(match.range(at: 1), in: lower),
              let days = Int(lower[daysRange]) else { return nil }

        guard let targetDate = calendar.date(byAdding: .day, value: days, to: now) else { return nil }

        let dayOfWeek = longDateFormatter.weekdaySymbols[calendar.component(.weekday, from: targetDate) - 1]
        let dateStr = longDateFormatter.string(from: targetDate)

        let widgetData = CalculationWidgetData(
            expression: "\(days) days from now",
            result: dateStr,
            unit: nil,
            symbol: nil,
            label: dayOfWeek
        )

        return ToolIO(
            text: "\(days) days from now is \(dayOfWeek), \(dateStr).",
            status: .ok,
            outputWidget: "MathWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// "30 days ago", "what day was 90 days ago"
    private static func matchDaysAgo(_ lower: String, calendar: Calendar, now: Date) -> ToolIO? {
        let regex = try? NSRegularExpression(pattern: #"(\d+)\s*days?\s*ago"#, options: .caseInsensitive)
        guard let match = regex?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let daysRange = Range(match.range(at: 1), in: lower),
              let days = Int(lower[daysRange]) else { return nil }

        guard let targetDate = calendar.date(byAdding: .day, value: -days, to: now) else { return nil }

        let dayOfWeek = longDateFormatter.weekdaySymbols[calendar.component(.weekday, from: targetDate) - 1]
        let dateStr = longDateFormatter.string(from: targetDate)

        let widgetData = CalculationWidgetData(
            expression: "\(days) days ago",
            result: dateStr,
            unit: nil,
            symbol: nil,
            label: dayOfWeek
        )

        return ToolIO(
            text: "\(days) days ago was \(dayOfWeek), \(dateStr).",
            status: .ok,
            outputWidget: "MathWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// "how many days between January 1 and March 15"
    private static func matchDaysBetween(_ lower: String, calendar: Calendar, original: String) -> ToolIO? {
        let regex = try? NSRegularExpression(pattern: #"(?:days?\s*between|from)\s+(.+?)\s+(?:and|to)\s+(.+?)[\s?.]*$"#, options: .caseInsensitive)
        guard let match = regex?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let r1 = Range(match.range(at: 1), in: lower),
              let r2 = Range(match.range(at: 2), in: lower) else { return nil }

        let dateStr1 = String(lower[r1])
        let dateStr2 = String(lower[r2])
        let now = Date()

        guard let date1 = parseNaturalDate(dateStr1, relativeTo: now),
              let date2 = parseNaturalDate(dateStr2, relativeTo: now) else { return nil }

        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: date1), to: calendar.startOfDay(for: date2)).day ?? 0)

        let widgetData = CalculationWidgetData(
            expression: original,
            result: "\(days)",
            unit: days == 1 ? " day" : " days",
            symbol: nil,
            label: "Days Between"
        )

        return ToolIO(
            text: "There are \(days) days between those dates.",
            status: .ok,
            outputWidget: "MathWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// "what day of the week was July 4, 1776" / "what day is December 25"
    private static func matchDayOfWeek(_ lower: String, calendar: Calendar, original: String) -> ToolIO? {
        let patterns = ["what day of the week was ", "what day of the week is ",
                        "what day was ", "what day is "]
        for pattern in patterns {
            guard let range = lower.range(of: pattern) else { continue }
            let dateStr = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "?")))
            guard !dateStr.isEmpty, let targetDate = parseNaturalDate(dateStr, relativeTo: Date()) else { continue }

            let dayOfWeek = longDateFormatter.weekdaySymbols[calendar.component(.weekday, from: targetDate) - 1]
            let dateFormatted = longDateFormatter.string(from: targetDate)

            let widgetData = CalculationWidgetData(
                expression: original,
                result: dayOfWeek,
                unit: nil,
                symbol: nil,
                label: dateFormatted
            )

            return ToolIO(
                text: "\(dateFormatted) is a \(dayOfWeek).",
                status: .ok,
                outputWidget: "MathWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
        return nil
    }

    /// Parses natural language dates: "Christmas", "March 25", "July 4 1776",
    /// "tomorrow", "next Friday", "new years", etc.
    /// Uses NSDataDetector for structured dates and manual parsing for holidays.
    private static func parseNaturalDate(_ text: String, relativeTo now: Date) -> Date? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "?.")))
        let lower = cleaned.lowercased()
        let calendar = Calendar.current

        // Common holidays (next occurrence)
        let holidays: [(names: [String], month: Int, day: Int)] = [
            (["christmas", "xmas", "christmas day"], 12, 25),
            (["new year", "new years", "new year's", "new years day", "new year's day"], 1, 1),
            (["valentine", "valentines", "valentine's", "valentines day", "valentine's day"], 2, 14),
            (["halloween"], 10, 31),
            (["independence day", "4th of july", "july 4th", "fourth of july"], 7, 4),
            (["st patricks", "st patrick's", "st patricks day", "saint patrick"], 3, 17),
        ]

        for holiday in holidays {
            if holiday.names.contains(where: { lower.contains($0) }) {
                var components = DateComponents()
                components.month = holiday.month
                components.day = holiday.day
                // Use current year, or next year if date has passed
                components.year = calendar.component(.year, from: now)
                if let date = calendar.date(from: components), date >= calendar.startOfDay(for: now) {
                    return date
                }
                components.year = calendar.component(.year, from: now) + 1
                return calendar.date(from: components)
            }
        }

        // Relative terms
        if lower == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: now) }
        if lower == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: now) }
        if lower == "today" { return now }

        // "next <weekday>"
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, day) in weekdays.enumerated() {
            if lower.hasPrefix("next \(day)") || lower == day {
                let targetWeekday = index + 1 // Calendar weekdays are 1-based
                let currentWeekday = calendar.component(.weekday, from: now)
                var daysAhead = targetWeekday - currentWeekday
                if daysAhead <= 0 { daysAhead += 7 }
                return calendar.date(byAdding: .day, value: daysAhead, to: now)
            }
        }

        // NSDataDetector for structured dates like "March 25", "July 4, 1776"
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let nsString = cleaned as NSString
            let matches = detector.matches(in: cleaned, options: [], range: NSRange(location: 0, length: nsString.length))
            if let match = matches.first, let date = match.date {
                return date
            }
        }

        // Try DateFormatter as last resort
        let formatters: [String] = ["MMMM d, yyyy", "MMMM d yyyy", "MMMM d", "MMM d, yyyy", "MMM d yyyy", "MMM d", "yyyy-MM-dd", "MM/dd/yyyy", "MM/dd"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in formatters {
            df.dateFormat = format
            if let date = df.date(from: cleaned) {
                // If no year was provided, use current year
                if !format.contains("yyyy") {
                    var components = calendar.dateComponents([.month, .day], from: date)
                    components.year = calendar.component(.year, from: now)
                    if let adjusted = calendar.date(from: components) {
                        return adjusted
                    }
                }
                return date
            }
        }

        return nil
    }

    // MARK: - Sanitizer

    /// Sanitizes user input into a safe expression string for NSExpression.
    /// Strips natural language, normalizes operators, and rejects anything
    /// that contains characters outside the safe set.
    /// Strips conversational prefixes ("what's", "calculate", "how much is")
    /// and trailing punctuation from the input for user-facing display.
    /// Parallel to `sanitize` but preserves the arithmetic expression
    /// shape rather than normalizing to NSExpression form.
    static func stripNaturalLanguageFluff(_ input: String) -> String {
        let prefixes = [
            "what's ", "what is ", "whats ", "calculate ", "compute ", "solve ",
            "how much is ", "what does ", "eval ", "evaluate ", "find ",
            "how much ",
        ]
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        // Trailing punctuation
        return s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    static func sanitize(_ input: String) -> String {
        var expr = input

        // Strip common natural language prefixes
        let prefixes = [
            "what's ", "what is ", "whats ", "calculate ", "compute ", "solve ",
            "how much is ", "what does ", "eval ", "evaluate ", "find ",
            "how much ",
        ]
        let lowered = expr.lowercased()
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                expr = String(expr.dropFirst(prefix.count))
                break
            }
        }

        // Strip trailing question marks, "equal", "equals", "="
        expr = expr.replacingOccurrences(of: "?", with: "")
        let trailingPatterns = [" equals", " equal", "="]
        for pattern in trailingPatterns {
            if expr.lowercased().hasSuffix(pattern) {
                expr = String(expr.dropLast(pattern.count))
            }
        }

        // Strip currency symbols and commas
        expr = expr.replacingOccurrences(of: "$", with: "")
        expr = expr.replacingOccurrences(of: "€", with: "")
        expr = expr.replacingOccurrences(of: "£", with: "")
        expr = expr.replacingOccurrences(of: ",", with: "")

        // Strip polite suffixes
        let politePatterns = [", please", " please"]
        for p in politePatterns {
            if expr.lowercased().hasSuffix(p) {
                expr = String(expr.dropLast(p.count))
            }
        }

        // Normalize operator symbols
        expr = expr.replacingOccurrences(of: "×", with: "*")
        expr = expr.replacingOccurrences(of: "÷", with: "/")
        expr = expr.replacingOccurrences(of: "x", with: "*")
        expr = expr.replacingOccurrences(of: "^", with: "**")

        // Normalize "%" symbol → "percent" for regex handling
        expr = expr.replacingOccurrences(of: "%", with: " percent ")

        // Handle "X percent of Y" → "(Y * X / 100)". Substitute the matched
        // span in place (don't clobber surrounding text) so loan-style inputs
        // like "$200000 loan at 6.5% for 30 years" fail the final letter check
        // and fall through to LLM normalization (which returns loan JSON).
        let percentPattern = try? NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)\s*percent\s*(?:of\s*)?(\d+(?:\.\d+)?)"#,
            options: .caseInsensitive
        )
        if let match = percentPattern?.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)),
           let r1 = Range(match.range(at: 1), in: expr),
           let r2 = Range(match.range(at: 2), in: expr),
           let mRange = Range(match.range, in: expr) {
            let pct = expr[r1]
            let base = expr[r2]
            expr.replaceSubrange(mRange, with: "(\(base) * \(pct) / 100.0)")
        }

        // Tolerant match: "X percent ... Y" where X is the percentage and
        // Y is the only remaining number. Catches:
        //   "15 percent tip on a $62.40 bill"
        //   "20 percent tax on 200"
        //   "10 percent off a $50 shirt"
        // Only applies if the strict pattern above didn't already reduce the
        // expression to a computable form.
        if expr.lowercased().contains("percent"),
           let tolerant = try? NSRegularExpression(
                pattern: #"(\d+(?:\.\d+)?)\s*percent\b[^\d]*\$?(\d+(?:\.\d+)?)"#,
                options: .caseInsensitive),
           let match = tolerant.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)),
           let r1 = Range(match.range(at: 1), in: expr),
           let r2 = Range(match.range(at: 2), in: expr),
           let mRange = Range(match.range, in: expr) {
            let pct = expr[r1]
            let base = expr[r2]
            expr.replaceSubrange(mRange, with: "(\(base) * \(pct) / 100.0)")
        }

        // Handle "square root of X" → "X ** 0.5"
        let sqrtPattern = try? NSRegularExpression(
            pattern: #"square\s*root\s*(?:of\s*)?(\d+(?:\.\d+)?)"#,
            options: .caseInsensitive
        )
        if let match = sqrtPattern?.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)),
           let r1 = Range(match.range(at: 1), in: expr) {
            expr = "\(expr[r1]) ** 0.5"
        }

        // Handle "X squared" → "X ** 2"
        let squaredPattern = try? NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)\s*squared"#,
            options: .caseInsensitive
        )
        if let match = squaredPattern?.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)),
           let r1 = Range(match.range(at: 1), in: expr) {
            expr = "\(expr[r1]) ** 2"
        }

        // Replace word operators
        expr = expr.replacingOccurrences(of: " plus ", with: " + ", options: .caseInsensitive)
        expr = expr.replacingOccurrences(of: " minus ", with: " - ", options: .caseInsensitive)
        expr = expr.replacingOccurrences(of: " times ", with: " * ", options: .caseInsensitive)
        expr = expr.replacingOccurrences(of: " divided by ", with: " / ", options: .caseInsensitive)
        expr = expr.replacingOccurrences(of: " mod ", with: " % ", options: .caseInsensitive)

        expr = expr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle "factorial of X" or "X!" → compute directly (max 20 to avoid overflow)
        if let factorialPattern = try? NSRegularExpression(
            pattern: #"(?:factorial\s*(?:of\s*)?(\d+)|(\d+)\s*!)"#,
            options: .caseInsensitive
        ),
           let match = factorialPattern.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)) {
            let numRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if let r = Range(numRange, in: expr), let n = Int(expr[r]), n >= 0, n <= 20 {
                let factorial = n < 2 ? 1 : (1...n).reduce(1, *)
                expr = "\(factorial)"
            }
        }

        // Force floating-point division to avoid integer truncation: "1000 / 7" → "1000.0 / 7.0"
        if let divPattern = try? NSRegularExpression(pattern: #"(?<!\.)(\b\d+)\s*/\s*(\d+\b)(?!\.)"#) {
            let range = NSRange(expr.startIndex..., in: expr)
            expr = divPattern.stringByReplacingMatches(in: expr, range: range, withTemplate: "$1.0 / $2.0")
        }

        // Final safety check: reject if any non-math characters remain
        let remaining = expr.unicodeScalars.filter { !allowedCharacters.contains($0) }
        if !remaining.isEmpty {
            return ""
        }

        if expr.trimmingCharacters(in: .whitespaces).isEmpty {
            return ""
        }

        return expr
    }
}

/// AppIntent wrapping CalculatorTool.
public struct CalculatorIntent: AppIntent {
    public static var title: LocalizedStringResource { "Calculate Math" }
    public static var description: IntentDescription? {
        IntentDescription("Performs math calculations using the iClaw CalculatorTool.")
    }

    @Parameter(title: "Expression")
    public var expression: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: expression, entities: nil)
        return .result(value: result.text)
    }
}
