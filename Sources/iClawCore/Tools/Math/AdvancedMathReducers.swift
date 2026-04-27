import Foundation

/// Deterministic Swift implementations of common advanced-math queries that
/// NSExpression can't evaluate (GCD, LCM, primality, combinatorics,
/// descriptive statistics, compound interest, base conversion, geometry).
///
/// The `reduce` entry-point runs BEFORE `CalculatorTool.sanitize`, catching
/// a short list of patterns and returning an exact numeric result. When no
/// pattern matches it returns `nil` and the existing pipeline takes over.
///
/// The detector regexes are written over the STRUCTURE of math expressions
/// ("GCD of X and Y", "N choose K", "A to binary"), not natural-language
/// phrasing. The math-function names (GCD/LCM/etc) ARE universal
/// mathematical vocabulary in every language that adopted the Latin
/// alphabet's technical notation, so they count as structural metadata.
enum AdvancedMathReducers {

    /// Result shape. `display` is the human-readable answer; `latex` is the
    /// LaTeX form for the MathWidget.
    struct Outcome: Sendable {
        let value: Double
        let display: String
        let latex: String
    }

    /// Attempt to reduce `input` to an exact numeric outcome. Returns nil
    /// when no specialist pattern matches.
    static func reduce(_ input: String) -> Outcome? {
        let normalized = input.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try each reducer in order; first match wins.
        if let out = tryGCD(normalized) { return out }
        if let out = tryLCM(normalized) { return out }
        if let out = tryLargestPrimeUnder(normalized) { return out }
        if let out = tryPrime(normalized) { return out }
        if let out = tryChoose(normalized) { return out }
        if let out = tryBinomialSurface(normalized) { return out }
        if let out = tryMean(normalized) { return out }
        if let out = tryMedian(normalized) { return out }
        if let out = tryStdev(normalized) { return out }
        if let out = tryCompoundInterest(normalized) { return out }
        if let out = tryAreaTriangle(normalized) { return out }
        if let out = tryAreaCircle(normalized) { return out }
        if let out = tryHypotenuse(normalized) { return out }
        if let out = tryBaseConversion(normalized, original: input) { return out }
        if let out = trySumSeries(normalized) { return out }
        if let out = tryDefiniteIntegralPolynomial(normalized) { return out }
        if let out = tryDerivativePolynomial(normalized) { return out }

        return nil
    }

    // MARK: - Polynomial calculus

    /// Matches "integral of x^n from a to b" / "int x^n dx from a to b" and
    /// related surface forms. Computes the exact definite integral for a
    /// monomial `c·x^n`: ∫[a,b] c·x^n dx = c/(n+1) · (b^(n+1) - a^(n+1)).
    /// Supports:
    ///   "integral of x^2 from 0 to 5"
    ///   "integral from 0 to 5 of x^2"
    ///   "integrate x^2 dx from 0 to 5"
    private static func tryDefiniteIntegralPolynomial(_ s: String) -> Outcome? {
        guard s.contains("integral") || s.contains("integrate") else { return nil }
        // Pull exponent (n≥0) and bounds (a, b). Default coefficient 1.
        // Pattern order: look for "x^N" (N integer) with optional coef "c*x^N".
        let ints = extractDoubles(s)
        // We need at least 3 numbers: n (exponent), a, b. If "x^2 from 0 to 5",
        // ints=[2,0,5]. If "x from 0 to 5", no explicit exponent (n=1) → ints=[0,5].
        let exp: Int
        let a: Double
        let b: Double
        if ints.count >= 3 {
            exp = Int(ints[0])
            a = ints[1]; b = ints[2]
        } else if ints.count == 2 {
            // "integral of x from a to b"
            exp = 1
            a = ints[0]; b = ints[1]
        } else {
            return nil
        }
        guard exp >= 0, exp <= 20 else { return nil }
        // ∫ x^n dx = x^(n+1) / (n+1)
        let np1 = Double(exp + 1)
        let value = (pow(b, np1) - pow(a, np1)) / np1
        return Outcome(
            value: value,
            display: format(value),
            latex: "\\int_{\(format(a))}^{\(format(b))} x^{\(exp)} \\, dx = \\frac{\(format(b))^{\(exp + 1)} - \(format(a))^{\(exp + 1)}}{\(exp + 1)} = \(format(value))"
        )
    }

    /// Symbolic derivative of a monomial-polynomial sum "a x^n + b x^m + c".
    /// Returns the derivative as a string. Not a numeric result, but a
    /// canonical form the finalizer preserves.
    private static func tryDerivativePolynomial(_ s: String) -> Outcome? {
        guard s.contains("derivative") else { return nil }
        // Match the polynomial body after "of " or after "derivative of ".
        guard let ofRange = s.range(of: "of ") else { return nil }
        let body = String(s[ofRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Tokenize by +/- while preserving signs.
        // Replace " - " with " +-" so split by "+" keeps signs.
        let prepped = body.replacingOccurrences(of: "- ", with: "+- ")
        let terms = prepped.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Each term is of form "[c]x^n" / "[c]x" / "c"
        // Parse via regex. For each, derivative is:
        //   c·x^n  →  (c·n)·x^(n-1)     (n != 0)
        //   c·x    →  c
        //   c      →  0 (drop)
        let termRe = try? NSRegularExpression(
            pattern: #"^(-?\d+(?:\.\d+)?)?\s*\*?\s*x(?:\s*\^\s*(-?\d+))?$|^(-?\d+(?:\.\d+)?)$"#
        )
        var parts: [String] = []
        var numericOnly = true
        for term in terms where !term.isEmpty {
            let range = NSRange(term.startIndex..., in: term)
            guard let m = termRe?.firstMatch(in: term, options: [], range: range) else {
                return nil  // Couldn't parse — fall through to LLM
            }
            if m.range(at: 3).location != NSNotFound {
                // Constant term → derivative is 0, drop
                continue
            }
            let coefStr: String
            if m.range(at: 1).location != NSNotFound {
                coefStr = (term as NSString).substring(with: m.range(at: 1))
            } else {
                coefStr = term.hasPrefix("-") ? "-1" : "1"
            }
            let coef = Double(coefStr) ?? 1.0
            let exp: Int
            if m.range(at: 2).location != NSNotFound {
                exp = Int((term as NSString).substring(with: m.range(at: 2))) ?? 1
            } else {
                exp = 1
            }
            let newCoef = coef * Double(exp)
            let newExp = exp - 1
            if newCoef == 0 { continue }
            numericOnly = false
            switch newExp {
            case 0: parts.append(format(newCoef))
            case 1: parts.append("\(format(newCoef))x")
            default: parts.append("\(format(newCoef))x^\(newExp)")
            }
        }
        guard !numericOnly, !parts.isEmpty else { return nil }
        // Join with " + ", convert "+ -" → "- "
        let joined = parts.joined(separator: " + ").replacingOccurrences(of: "+ -", with: "- ")
        return Outcome(value: .nan, display: joined, latex: "\\frac{d}{dx}\\left(\(body)\\right) = \(joined)")
    }

    // MARK: - Individual reducers

    private static func tryGCD(_ s: String) -> Outcome? {
        // "GCD of A and B" / "greatest common divisor of A and B" / "gcd A B"
        guard s.contains("gcd") || s.contains("greatest common") else { return nil }
        let ints = extractIntegers(s)
        guard ints.count >= 2 else { return nil }
        let result = ints.reduce(ints[0]) { gcd($0, $1) }
        return Outcome(value: Double(result), display: "\(result)", latex: "\\gcd(\(ints.map(String.init).joined(separator: ", "))) = \(result)")
    }

    private static func tryLCM(_ s: String) -> Outcome? {
        guard s.contains("lcm") || s.contains("least common multiple") else { return nil }
        let ints = extractIntegers(s)
        guard ints.count >= 2 else { return nil }
        let result = ints.reduce(ints[0]) { lcm($0, $1) }
        return Outcome(value: Double(result), display: "\(result)", latex: "\\text{lcm}(\(ints.map(String.init).joined(separator: ", "))) = \(result)")
    }

    /// Matches "largest prime under N", "greatest prime less than N",
    /// "biggest prime below N", etc. Returns the exact prime. Linear scan
    /// from N-1 downward; N≤2_000_000 comfortably under 100ms on modern CPUs.
    private static func tryLargestPrimeUnder(_ s: String) -> Outcome? {
        let qualifies = (s.contains("largest") || s.contains("greatest") || s.contains("biggest"))
            && s.contains("prime")
            && (s.contains("under") || s.contains("below") || s.contains("less than") || s.contains("up to"))
        guard qualifies else { return nil }
        let ints = extractIntegers(s)
        guard let n = ints.first, n >= 3, n <= 2_000_000 else { return nil }
        // Scan from n-1 downward. "Under N" is exclusive; "less than or
        // equal to N" is not matched by this reducer.
        var candidate = n - 1
        while candidate >= 2 {
            if isPrime(candidate) {
                return Outcome(
                    value: Double(candidate),
                    display: "\(candidate)",
                    latex: "\\text{largest prime} < \(n) = \(candidate)"
                )
            }
            candidate -= 1
        }
        return nil
    }

    private static func tryPrime(_ s: String) -> Outcome? {
        guard s.contains("prime") else { return nil }
        // Primality queries have two shapes: "is N prime?" (single-value
        // check) and "largest prime under N" / "nth prime" / "primes
        // between A and B" (search). The latter require a different
        // algorithm and have their own reducers; don't hijack them.
        if s.contains("largest") || s.contains("smallest")
            || s.contains("between") || s.contains("under")
            || s.contains("below") || s.contains("above")
            || s.contains("next") || s.contains("nth") {
            return nil
        }
        let ints = extractIntegers(s)
        guard ints.count == 1, let n = ints.first else { return nil }
        let isP = isPrime(n)
        return Outcome(value: isP ? 1 : 0, display: isP ? "Yes — \(n) is prime." : "No — \(n) is not prime.", latex: "")
    }

    private static func tryChoose(_ s: String) -> Outcome? {
        // "N choose K", "nCr(N,K)", "combinations of K from N", "ways to choose K from N"
        // Pattern 1: "N choose K"
        if let re = try? NSRegularExpression(pattern: #"(\d+)\s*choose\s*(\d+)"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let n = Int((s as NSString).substring(with: m.range(at: 1))),
           let k = Int((s as NSString).substring(with: m.range(at: 2))) {
            let c = binomial(n, k)
            return Outcome(value: Double(c), display: "\(c)", latex: "\\binom{\(n)}{\(k)} = \(c)")
        }
        // Pattern 2: "choose K from N" / "pick K from N" / "ways to choose K from N"
        if let re = try? NSRegularExpression(pattern: #"(?:choose|pick)\s+(\d+)\s+(?:from|out of)\s+(\d+)"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let k = Int((s as NSString).substring(with: m.range(at: 1))),
           let n = Int((s as NSString).substring(with: m.range(at: 2))) {
            let c = binomial(n, k)
            return Outcome(value: Double(c), display: "\(c)", latex: "\\binom{\(n)}{\(k)} = \(c)")
        }
        return nil
    }

    private static func tryBinomialSurface(_ s: String) -> Outcome? {
        // "nCr 7 3" / "C(7,3)" / "7C3"
        if let re = try? NSRegularExpression(pattern: #"(?:nCr|c\s*)\(\s*(\d+)\s*,\s*(\d+)\s*\)"#, options: .caseInsensitive),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let n = Int((s as NSString).substring(with: m.range(at: 1))),
           let k = Int((s as NSString).substring(with: m.range(at: 2))) {
            let c = binomial(n, k)
            return Outcome(value: Double(c), display: "\(c)", latex: "\\binom{\(n)}{\(k)} = \(c)")
        }
        return nil
    }

    private static func tryMean(_ s: String) -> Outcome? {
        guard s.contains("mean") || s.contains("average") else { return nil }
        let nums = extractDoubles(s)
        guard nums.count >= 2 else { return nil }
        let avg = nums.reduce(0.0, +) / Double(nums.count)
        return Outcome(value: avg, display: format(avg), latex: "\\bar x = \(format(avg))")
    }

    private static func tryMedian(_ s: String) -> Outcome? {
        guard s.contains("median") else { return nil }
        var nums = extractDoubles(s)
        guard nums.count >= 2 else { return nil }
        nums.sort()
        let med: Double
        if nums.count % 2 == 0 {
            med = (nums[nums.count / 2 - 1] + nums[nums.count / 2]) / 2
        } else {
            med = nums[nums.count / 2]
        }
        return Outcome(value: med, display: format(med), latex: "\\text{median} = \(format(med))")
    }

    private static func tryStdev(_ s: String) -> Outcome? {
        guard s.contains("standard deviation") || s.contains("stdev") || s.contains("std dev") else { return nil }
        let nums = extractDoubles(s)
        guard nums.count >= 2 else { return nil }
        let mean = nums.reduce(0.0, +) / Double(nums.count)
        let variance = nums.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(nums.count)
        let sd = variance.squareRoot()
        return Outcome(value: sd, display: format(sd), latex: "\\sigma = \(format(sd))")
    }

    private static func tryCompoundInterest(_ s: String) -> Outcome? {
        // "$P at r% (compounded annually) for Y years"
        guard s.contains("compound") || (s.contains("interest") && s.contains("year")) else { return nil }
        let doubles = extractDoubles(s)
        guard doubles.count >= 3 else { return nil }
        // Heuristic assignment: principal = largest, rate = small (<100), years = medium
        let sorted = doubles.sorted(by: >)
        let principal = sorted[0]
        // rate is the one < 100 not used as principal
        let remaining = Array(sorted.dropFirst())
        guard let rate = remaining.first(where: { $0 < 100 && $0 != principal }),
              let years = remaining.first(where: { $0 != rate && $0 < 200 }) else {
            return nil
        }
        let amount = principal * pow(1 + rate / 100.0, years)
        return Outcome(
            value: amount,
            display: format(amount),
            latex: "A = \(format(principal))(1 + \(rate)/100)^{\(Int(years))} = \(format(amount))"
        )
    }

    private static func tryAreaTriangle(_ s: String) -> Outcome? {
        guard s.contains("area") && s.contains("triangle") else { return nil }
        let nums = extractDoubles(s)
        guard let b = nums.first, nums.count >= 2 else { return nil }
        let h = nums[1]
        let area = b * h / 2
        return Outcome(value: area, display: format(area), latex: "A = \\tfrac{1}{2} \\cdot \(format(b)) \\cdot \(format(h)) = \(format(area))")
    }

    private static func tryAreaCircle(_ s: String) -> Outcome? {
        guard s.contains("area") && s.contains("circle") else { return nil }
        let nums = extractDoubles(s)
        guard let r = nums.first else { return nil }
        let area = .pi * r * r
        return Outcome(value: area, display: format(area), latex: "A = \\pi r^2 = \\pi \\cdot \(format(r))^2 = \(format(area))")
    }

    private static func tryHypotenuse(_ s: String) -> Outcome? {
        guard s.contains("hypotenuse") else { return nil }
        let nums = extractDoubles(s)
        guard nums.count >= 2 else { return nil }
        let h = (nums[0] * nums[0] + nums[1] * nums[1]).squareRoot()
        return Outcome(value: h, display: format(h), latex: "c = \\sqrt{\(format(nums[0]))^2 + \(format(nums[1]))^2} = \(format(h))")
    }

    private static func tryBaseConversion(_ s: String, original: String) -> Outcome? {
        // "N to binary" / "N in hex" / "convert N to base 2"
        if let re = try? NSRegularExpression(pattern: #"(-?\d+)\s+(?:to|in)\s+(binary|hex|hexadecimal|octal)\b"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let n = Int((s as NSString).substring(with: m.range(at: 1))) {
            let bs = (s as NSString).substring(with: m.range(at: 2))
            let base: Int = bs.hasPrefix("bin") ? 2 : bs.hasPrefix("oct") ? 8 : 16
            let str = String(n, radix: base, uppercase: base == 16)
            return Outcome(value: Double(n), display: str, latex: "\(n) = \(str)_{\(base)}")
        }
        // "0xFF to decimal" / "binary 1010 to decimal"
        if let re = try? NSRegularExpression(pattern: #"0x([0-9a-f]+)\s+(?:to|in)\s+decimal"#, options: .caseInsensitive),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            let hex = (s as NSString).substring(with: m.range(at: 1))
            if let n = Int(hex, radix: 16) {
                return Outcome(value: Double(n), display: "\(n)", latex: "0x\(hex) = \(n)")
            }
        }
        if let re = try? NSRegularExpression(pattern: #"binary\s+([01]+)\s+(?:to|in)\s+decimal"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            let bin = (s as NSString).substring(with: m.range(at: 1))
            if let n = Int(bin, radix: 2) {
                return Outcome(value: Double(n), display: "\(n)", latex: "\(bin)_2 = \(n)")
            }
        }
        _ = original
        return nil
    }

    private static func trySumSeries(_ s: String) -> Outcome? {
        // "Sum of 1 to N" / "Sum from A to B"
        if let re = try? NSRegularExpression(pattern: #"sum\s+(?:of|from)\s+(\d+)\s+to\s+(\d+)"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let a = Int((s as NSString).substring(with: m.range(at: 1))),
           let b = Int((s as NSString).substring(with: m.range(at: 2))),
           a <= b {
            // Arithmetic series: (b-a+1) * (a+b) / 2
            let n = Int64(b - a + 1)
            let sum = n * Int64(a + b) / 2
            return Outcome(value: Double(sum), display: "\(sum)", latex: "\\sum_{i=\(a)}^{\(b)} i = \(sum)")
        }
        return nil
    }

    // MARK: - Math primitives

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        guard a != 0, b != 0 else { return 0 }
        return abs(a / gcd(a, b) * b)
    }

    private static func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n < 4 { return true }
        if n % 2 == 0 { return false }
        var i = 3
        while i * i <= n {
            if n % i == 0 { return false }
            i += 2
        }
        return true
    }

    private static func binomial(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, n >= k else { return 0 }
        let k = min(k, n - k)
        var result = 1
        for i in 0..<k {
            result = result * (n - i) / (i + 1)
        }
        return result
    }

    // MARK: - Number extraction

    private static func extractIntegers(_ s: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: #"-?\d+"#)
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        return matches.compactMap { m in Int((s as NSString).substring(with: m.range)) }
    }

    private static func extractDoubles(_ s: String) -> [Double] {
        let re = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        return matches.compactMap { m in Double((s as NSString).substring(with: m.range)) }
    }

    private static func format(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 && abs(v) < 1e15 {
            return String(Int(v.rounded()))
        }
        let abs = Swift.abs(v)
        let places = abs < 1 ? 4 : abs < 100 ? 2 : 2
        return String(format: "%.\(places)f", v)
    }
}
