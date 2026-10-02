// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finds how a dubbed audio track lines up with the original one.
//
// A dub almost always shares the music and effects with the original — only the voices differ. Both tracks
// are reduced to an "onset" curve (how much the loudness jumps, 100 times per second); the cross-correlation
// of the two curves, computed with Accelerate's FFT, peaks at the lag where they match. The same is done for
// the usual frame-rate speed differences (PAL 25 fps against 23.976 fps film etc.), and the best match wins.
// Shorter windows spread over the film then check that the offset is the same everywhere (if it is not,
// the dub probably comes from a different edit of the film).

import Accelerate
import Foundation

public struct AudioSyncResult: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let time: Double     // movie time of the window centre
        public let offset: Double   // offset measured in that window
    }

    /// movie time = source time × stretch + offset
    public var offset: Double
    public var stretch: Double
    /// How clearly the best match stands out (peak height in standard deviations).
    public var confidence: Double
    public var points: [Point]
    /// Largest difference between the windows' offsets and the overall offset (seconds).
    public var spread: Double

    public var isReliable: Bool { confidence >= 12 }
    public var isConsistent: Bool { points.count < 3 || spread <= 0.12 }
}

public enum AudioSyncError: LocalizedError {
    case tooShort
    case noMatch

    public var errorDescription: String? {
        switch self {
        case .tooShort: return L("The audio is too short to synchronize")
        case .noMatch: return L("No match found — the tracks do not seem to share music and effects")
        }
    }
}

public enum AudioSync {
    /// Feature frames per second.
    public static let frameRate = 100.0
    static let sampleRate = 8000
    static var samplesPerFrame: Int { Int(Double(sampleRate) / frameRate) }

    // MARK: - Features

    /// Decodes one audio stream (mono, 8 kHz) and returns its onset curve, 100 values per second.
    public static func features(of url: URL, streamIndex: Int, tools: ToolPaths, duration: Double? = nil,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        guard let ffmpeg = tools.ffmpeg else { throw ProcessingError.missingTool("ffmpeg") }
        let acc = EnergyAccumulator(samplesPerFrame: samplesPerFrame)
        let expectedFrames = (duration ?? 0) * frameRate
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path, "-map", "0:\(streamIndex)",
                    "-vn", "-sn", "-dn", "-ac", "1", "-ar", "\(sampleRate)", "-f", "f32le", "pipe:1"]
        let r = try await ProcessRunner.run(ffmpeg, args, onStdoutData: { data in
            acc.add(data)
            if let progress, expectedFrames > 0 { progress(min(1, Double(acc.frameCount) / expectedFrames)) }
        }, keepStdout: false)
        guard r.status == 0 else {
            throw ProcessingError.failed(L("Could not decode the audio: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return onsets(fromEnergies: acc.finish())
    }

    /// Log-energy rise per frame (half-wave rectified difference), normalized to zero mean and unit variance.
    static func onsets(fromEnergies energies: [Float]) -> [Float] {
        guard energies.count > 2 else { return [] }
        var logE = energies.map { log10($0 + 1e-10) }
        var out = [Float](repeating: 0, count: logE.count)
        for i in 1..<logE.count { out[i] = max(0, logE[i] - logE[i - 1]) }
        logE = []
        return normalized(out)
    }

    static func normalized(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(x, 1, nil, 1, &mean, &sd, vDSP_Length(x.count))
        guard sd > 1e-9 else { return [Float](repeating: 0, count: x.count) }
        var out = [Float](repeating: 0, count: x.count)
        vDSP_normalize(x, 1, &out, 1, &mean, &sd, vDSP_Length(x.count))
        return out
    }

    // MARK: - Matching

    /// Full synchronization: decodes both tracks and analyzes them.
    public static func synchronize(reference: URL, referenceStream: Int, referenceDuration: Double,
                                   candidate: URL, candidateStream: Int, candidateDuration: Double,
                                   tools: ToolPaths, maxOffset: Double = 900,
                                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> AudioSyncResult {
        let box = ProgressBox(progress)
        async let ref = features(of: reference, streamIndex: referenceStream, tools: tools,
                                 duration: referenceDuration) { box.set(0, $0) }
        async let cand = features(of: candidate, streamIndex: candidateStream, tools: tools,
                                  duration: candidateDuration) { box.set(1, $0) }
        let (r, c) = try await (ref, cand)
        try Task.checkCancellation()
        return try analyze(reference: r, candidate: c, maxOffset: maxOffset)
    }

    /// Finds offset and speed ratio between two onset curves (see `features`).
    public static func analyze(reference: [Float], candidate: [Float], maxOffset: Double = 900) throws -> AudioSyncResult {
        guard reference.count > 30 * Int(frameRate), candidate.count > 30 * Int(frameRate) else { throw AudioSyncError.tooShort }

        // 1) Try the usual speed ratios on the whole film; keep the clearest match
        var best: (stretch: Double, lag: Double, z: Double)?
        for (ratio, _) in AddedAudio.knownStretches {
            let scaled = ratio == 1 ? candidate : resample(candidate, ratio: ratio)
            guard let m = bestLag(reference, scaled, maxLag: Int(maxOffset * frameRate)) else { continue }
            // Prefer 1:1 unless another ratio is clearly better
            let score = ratio == 1 ? m.z * 1.15 : m.z
            if best == nil || score > (best!.stretch == 1 ? best!.z * 1.15 : best!.z) {
                best = (ratio, m.lag, m.z)
            }
        }
        guard let found = best, found.z >= 8 else { throw AudioSyncError.noMatch }

        // 2) Check the offset in windows spread over the film
        let scaled = found.stretch == 1 ? candidate : resample(candidate, ratio: found.stretch)
        let window = Int(240 * frameRate), margin = Int(4 * frameRate)
        let lag0 = Int(found.lag.rounded())
        let start = max(0, lag0), end = min(reference.count, scaled.count + lag0)
        var points: [AudioSyncResult.Point] = []
        var attempted = 0
        if end - start > window {
            let count = min(10, max(3, (end - start) / window))
            let step = (end - start - window) / max(1, count - 1)
            for w in 0..<count {
                let r0 = start + w * step
                let refPart = Array(reference[r0..<min(reference.count, r0 + window)])
                let c0 = r0 - lag0 - margin
                let lo = max(0, c0), hi = min(scaled.count, r0 - lag0 + window + margin)
                guard hi - lo > window / 2 else { continue }
                attempted += 1
                let candPart = Array(scaled[lo..<hi])
                guard let m = bestLag(refPart, candPart, maxLag: (r0 - lo) + margin), m.z >= 6 else { continue }
                // refPart[t] ≈ candPart[t - m.lag]  →  reference frame r0 + t ≈ scaled frame lo + t - m.lag
                let lag = Double(r0 - lo) + m.lag
                points.append(.init(time: Double(r0 + window / 2) / frameRate, offset: lag / frameRate))
            }
        }

        // A real match shows up in most windows; a chance peak in unrelated audio does not
        if attempted >= 2 && points.count * 2 < attempted { throw AudioSyncError.noMatch }

        var offset = found.lag / frameRate
        if points.count >= 3 {
            let sorted = points.map(\.offset).sorted()
            offset = sorted[sorted.count / 2]
        }
        let spread = points.map { abs($0.offset - offset) }.max() ?? 0
        return AudioSyncResult(offset: offset, stretch: found.stretch, confidence: found.z, points: points, spread: spread)
    }

    /// Stretches a curve in time: output frame j takes input frame j / ratio (linear interpolation).
    static func resample(_ x: [Float], ratio: Double) -> [Float] {
        let n = Int(Double(x.count) * ratio)
        guard n > 1, x.count > 1 else { return x }
        var idx = [Float](repeating: 0, count: n)
        var start: Float = 0, step = Float(1 / ratio)
        vDSP_vramp(&start, &step, &idx, 1, vDSP_Length(n))
        var limit = Float(x.count - 2)
        var zero: Float = 0
        vDSP_vclip(idx, 1, &zero, &limit, &idx, 1, vDSP_Length(n))
        var out = [Float](repeating: 0, count: n)
        vDSP_vlint(x, idx, 1, &out, 1, vDSP_Length(n), vDSP_Length(x.count))
        return out
    }

    /// The lag (in frames, sub-frame precise) where `b` delayed by lag best matches `a`: a[t + lag] ≈ b[t].
    /// Returns the lag and how many standard deviations the peak stands above the other lags.
    static func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> (lag: Double, z: Double)? {
        let corr = crossCorrelation(a, b)
        let n = corr.count
        guard n > 0 else { return nil }
        let maxPos = min(maxLag, a.count - 1, n / 2 - 1)
        let maxNeg = min(maxLag, b.count - 1, n / 2 - 1)
        // Gather the allowed lags: 0...maxPos and -maxNeg...-1 (stored at n - k)
        var values = [Float](); values.reserveCapacity(maxPos + maxNeg + 1)
        var lags = [Int](); lags.reserveCapacity(maxPos + maxNeg + 1)
        for k in -maxNeg...maxPos {
            values.append(corr[k >= 0 ? k : n + k])
            lags.append(k)
        }
        guard values.count > 10 else { return nil }
        var maxV: Float = 0; var maxI: vDSP_Length = 0
        vDSP_maxvi(values, 1, &maxV, &maxI, vDSP_Length(values.count))
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &sd, vDSP_Length(values.count))
        guard sd > 0 else { return nil }
        let i = Int(maxI)
        // Parabolic interpolation around the peak for sub-frame precision
        var frac = 0.0
        if i > 0 && i < values.count - 1 {
            let y0 = Double(values[i - 1]), y1 = Double(values[i]), y2 = Double(values[i + 1])
            let d = y0 - 2 * y1 + y2
            if abs(d) > 1e-12 { frac = max(-0.5, min(0.5, 0.5 * (y0 - y2) / d)) }
        }
        return (Double(lags[i]) + frac, Double((maxV - mean) / sd))
    }

    /// Circular cross-correlation r[k] = Σ a[t + k]·b[t] via real FFTs (zero-padded, so it is linear).
    static func crossCorrelation(_ a: [Float], _ b: [Float]) -> [Float] {
        let needed = a.count + b.count
        let log2n = vDSP_Length(ceil(log2(Double(needed))))
        let n = 1 << Int(log2n)
        let half = n / 2
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
            var padded = x + [Float](repeating: 0, count: n - x.count)
            var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeMutableBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            padded = []
            return (re, im)
        }

        let (ar, ai) = forward(a)
        let (br, bi) = forward(b)
        // A · conj(B); element 0 holds DC (real part) and Nyquist (imaginary part) separately
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        for k in 0..<half {
            if k == 0 {
                re[0] = ar[0] * br[0]
                im[0] = ai[0] * bi[0]
            } else {
                re[k] = ar[k] * br[k] + ai[k] * bi[k]
                im[k] = ai[k] * br[k] - ar[k] * bi[k]
            }
        }
        var out = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        return out
    }
}

/// Turns streamed f32le samples into per-frame mean energy without keeping the audio in memory.
final class EnergyAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let samplesPerFrame: Int
    private var leftover = Data()
    private var sum: Float = 0
    private var inFrame = 0
    private var energies: [Float] = []

    init(samplesPerFrame: Int) {
        self.samplesPerFrame = samplesPerFrame
        energies.reserveCapacity(1 << 20)
    }

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return energies.count }

    func add(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        var bytes = leftover
        bytes.append(data)
        let usable = bytes.count - bytes.count % 4
        bytes.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for i in 0..<(usable / 4) {
                let v = samples[i]
                sum += v * v
                inFrame += 1
                if inFrame == samplesPerFrame {
                    energies.append(sum / Float(samplesPerFrame))
                    sum = 0
                    inFrame = 0
                }
            }
        }
        leftover = usable < bytes.count ? bytes.subdata(in: usable..<bytes.count) : Data()
    }

    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return energies
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Double] = [0, 0]
    private let report: (@Sendable (Double) -> Void)?
    init(_ report: (@Sendable (Double) -> Void)?) { self.report = report }
    func set(_ i: Int, _ v: Double) {
        lock.lock(); parts[i] = v; let total = (parts[0] + parts[1]) / 2; lock.unlock()
        report?(total)
    }
}
