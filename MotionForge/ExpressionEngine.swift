// ExpressionEngine.swift — After-Effects-style property expressions on JavaScriptCore.
// Globals: time, index, value.  Functions: wiggle, linear, ease, clamp, random.
// The result of the last expression is the property value, like AE.
// A JSContext is not thread-safe: use one engine per thread (preview = main, export = its own).

import Foundation
import JavaScriptCore

final class ExpressionEngine {
    private let js: JSContext
    private(set) var lastError: String?

    init() {
        js = JSContext()
        js.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString() ?? "Unknown expression error"
        }
        js.evaluateScript(Self.prelude)
    }

    /// Returns nil when the expression is empty, throws a JS error, or does not produce a finite number.
    func evaluate(_ source: String, time: Double, index: Int, value: Double, seed: Int) -> Double? {
        lastError = nil
        js.setObject(time,  forKeyedSubscript: "time" as NSString)
        js.setObject(index, forKeyedSubscript: "index" as NSString)
        js.setObject(value, forKeyedSubscript: "value" as NSString)
        js.setObject(seed,  forKeyedSubscript: "__seed" as NSString)
        guard let result = js.evaluateScript(source), lastError == nil, result.isNumber else { return nil }
        let d = result.toDouble()
        return d.isFinite ? d : nil
    }

    /// Human-readable problem with `source`, or nil when it evaluates to a number.
    func validate(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if evaluate(trimmed, time: 0, index: 1, value: 0, seed: 1) != nil { return nil }
        return lastError ?? "The expression must end in a number."
    }

    private static let prelude = """
    var __seed = 1;
    function __h(n) { n = Math.sin(n * 127.1 + __seed * 311.7) * 43758.5453; return n - Math.floor(n); }
    function __noise(x) {
      var i = Math.floor(x), f = x - i;
      f = f * f * (3 - 2 * f);
      return (__h(i) * (1 - f) + __h(i + 1) * f) * 2 - 1;
    }
    function wiggle(freq, amp, octaves, ampMult, t) {
      octaves = octaves || 1;
      ampMult = (ampMult === undefined) ? 0.5 : ampMult;
      t = (t === undefined) ? time : t;
      var sum = 0, a = amp, f = freq;
      for (var o = 0; o < octaves; o++) { sum += a * __noise(t * f + o * 17.3); f *= 2; a *= ampMult; }
      return value + sum;
    }
    function clamp(v, lo, hi) { return Math.min(Math.max(v, lo), hi); }
    function linear(t, tMin, tMax, v1, v2) {
      var u = clamp((t - tMin) / (tMax - tMin), 0, 1);
      return v1 + (v2 - v1) * u;
    }
    function ease(t, tMin, tMax, v1, v2) {
      var u = clamp((t - tMin) / (tMax - tMin), 0, 1);
      u = u * u * (3 - 2 * u);
      return v1 + (v2 - v1) * u;
    }
    function random(lo, hi) {
      if (hi === undefined) { hi = lo === undefined ? 1 : lo; lo = 0; }
      return lo + (hi - lo) * __h(Math.floor(time * 30) + 101);
    }
    """
}
