import Foundation
import CoreGraphics
import simd
import Accelerate
// MUST NOT import AVFoundation, UIKit, CoreImage, Vision (AC29)

/// Computes a 3×3 homography matrix that maps image points to court points
/// using the Direct Linear Transform (DLT) algorithm with SVD via Accelerate.
///
/// The returned `simd_float3x3` is column-major (simd convention).  Elements
/// are laid out so that `M[c][r] == h[3*r + c]`, where `h` is the row-major
/// 9-vector `[h00,h01,h02, h10,h11,h12, h20,h21,h22]` with `h22 == 1`.
///
/// **Forward-mapping convention (pinned — what Phase 3 consumes):**
/// ```swift
/// let p = H * simd_float3(Float(x), Float(y), 1)
/// let court = (p.x / p.z, p.y / p.z)
/// ```
public enum HomographyService {

    /// Solves the 4-point DLT homography mapping `imagePoints` → `courtPoints`.
    ///
    /// - Parameters:
    ///   - imagePoints: Four source points, in `[TL, TR, BL, BR]` order.
    ///   - courtPoints: Four destination points, in the same order.
    /// - Returns: A normalized `simd_float3x3` with `H[2][2] == 1`, or `nil`
    ///   on: count ≠ 4 (either list or mismatched), degenerate/collinear
    ///   configuration (singular-ratio guard), or |h22| < 1e-9.
    public static func compute(
        imagePoints: [CGPoint],
        courtPoints: [CGPoint]
    ) -> simd_float3x3? {

        // 1. Guards (AC5, AC6) — mismatched counts fail the same guard.
        guard imagePoints.count == 4, courtPoints.count == 4 else { return nil }

        // 2. Build the 8×9 DLT matrix A in double precision, column-major for
        //    LAPACK (Fortran convention: column-major, A[col * M + row]).
        //    For each correspondence (x,y) → (u,v) add two rows:
        //      row_even: [-x, -y, -1,  0,  0,  0, u·x, u·y, u]
        //      row_odd:  [ 0,  0,  0, -x, -y, -1, v·x, v·y, v]
        let M = 8
        let N = 9
        var A = [Double](repeating: 0.0, count: M * N)  // column-major

        for i in 0..<4 {
            let x = Double(imagePoints[i].x)
            let y = Double(imagePoints[i].y)
            let u = Double(courtPoints[i].x)
            let v = Double(courtPoints[i].y)

            let row0 = 2 * i       // even row for this correspondence
            let row1 = 2 * i + 1   // odd row

            // Macro: A[col*M + row]
            // row0: [-x, -y, -1,  0,  0,  0, u*x, u*y,  u]
            A[0 * M + row0] = -x
            A[1 * M + row0] = -y
            A[2 * M + row0] = -1.0
            // cols 3,4,5 remain 0.0
            A[6 * M + row0] = u * x
            A[7 * M + row0] = u * y
            A[8 * M + row0] = u

            // row1: [0, 0, 0, -x, -y, -1, v*x, v*y, v]
            // cols 0,1,2 remain 0.0
            A[3 * M + row1] = -x
            A[4 * M + row1] = -y
            A[5 * M + row1] = -1.0
            A[6 * M + row1] = v * x
            A[7 * M + row1] = v * y
            A[8 * M + row1] = v
        }

        // 3. Solve for the null vector via SVD using Accelerate dgesdd_.
        //
        //    dgesdd_ (JOBZ='A') returns:
        //      S  — min(M,N)=8 singular values, DESCENDING order
        //      U  — M×M = 8×8 left singular vectors (column-major)
        //      VT — N×N = 9×9 right singular vectors, each ROW is a right
        //           singular vector (column-major storage).
        //
        //    The null vector of A is the right singular vector for the smallest
        //    singular value — i.e. the LAST ROW of VT.
        //    In column-major VT[9×9]: element (row r, col c) = vt[c * 9 + r].
        //    Last row → r = 8:  h[c] = vt[c * 9 + 8]  for c in 0..<9.
        //
        //    JOBZ='A' (not 'S') is required because 'S' gives only min(M,N)=8
        //    rows of VT; we need row 8 (index 8), which is only present with 'A'.

        var jobz: Int8 = Int8(bitPattern: UInt8(ascii: "A"))
        var m: Int32 = Int32(M)
        var n: Int32 = Int32(N)
        var lda: Int32 = Int32(M)
        var ldu: Int32 = Int32(M)
        var ldvt: Int32 = Int32(N)
        var info: Int32 = 0

        var S  = [Double](repeating: 0.0, count: 8)   // min(M,N) = 8 singular values
        var U  = [Double](repeating: 0.0, count: M * M)   // 8×8
        var VT = [Double](repeating: 0.0, count: N * N)   // 9×9
        var iwork = [Int32](repeating: 0, count: 8 * 8)   // 8 * min(M,N) = 64

        // ponytail: dgesdd_ is deprecated since macOS 13.3 in favour of the new LAPACK
        // interface (ACCELERATE_NEW_LAPACK). Migrating requires adding a swift-driver flag
        // in Package.swift, which is banned by AC28 (no new dependencies / Package.swift
        // untouched). OQ-1 mandates dgesdd_; upgrade path is a Package.swift swiftSettings
        // unsafeFlags change in a later maintenance task once AC28 is relaxed.

        // Workspace query: pass lwork = -1, read optimal size from work[0].
        var lwork: Int32 = -1
        var workQuery = [Double](repeating: 0.0, count: 1)
        dgesdd_(
            &jobz, &m, &n,
            &A, &lda,
            &S,
            &U, &ldu,
            &VT, &ldvt,
            &workQuery, &lwork,
            &iwork, &info
        )
        guard info == 0 else { return nil }

        // Full SVD solve.
        lwork = Int32(workQuery[0])
        var work = [Double](repeating: 0.0, count: Int(lwork))
        dgesdd_(
            &jobz, &m, &n,
            &A, &lda,
            &S,
            &U, &ldu,
            &VT, &ldvt,
            &work, &lwork,
            &iwork, &info
        )
        guard info == 0 else { return nil }

        // 4. Degenerate / collinear guard (AC4 — pinned criterion, no coder discretion).
        //    S is descending: S[0] is largest, S[7] is smallest (of the 8 computed).
        //    A well-posed 4-point set has rank(A)=8, so all 8 singular values > 0.
        //    A collinear / degenerate set drops rank and S[7] collapses toward 0.
        //    Criterion: S[7] / S[0] < 1e-6 → degenerate → return nil.
        //
        //    DO NOT use a determinant or element-magnitude guard: the AC2 offset-rect
        //    is a *valid* homography whose det ≈ (1/1820)·(1/1030) ≈ 5.3e-7, so
        //    abs(det) < 1e-6 would wrongly reject it (AC4 note in plan §2.1.1).
        guard S[0] > 0, S[7] / S[0] >= 1e-6 else { return nil }

        // Extract the null vector from the LAST ROW of VT (column-major 9×9).
        // Row index 8: h[c] = VT[c * 9 + 8]  for c in 0..<9.
        var h = (0..<9).map { VT[$0 * 9 + 8] }

        // 5. Scale-normalize so h[8] (h22) == 1.0.
        //    A valid court homography never has h22 == 0.
        guard abs(h[8]) >= 1e-9 else { return nil }
        let scale = h[8]
        h = h.map { $0 / scale }

        // 6. h is now the row-major 9-vector [h00,h01,h02, h10,h11,h12, h20,h21,h22].
        //    This is the single source of truth from which both the matrix and the
        //    persisted CourtCalibration.homographyMatrix are derived.

        // 7. Build simd_float3x3 using init(columns:).
        //    simd_float3x3 is column-major: M[c][r] is element (row r, col c).
        //    We want M[c][r] == h[3*r + c]:
        //      col 0: [h[0], h[3], h[6]]  (r=0,1,2 → h00, h10, h20)
        //      col 1: [h[1], h[4], h[7]]  (r=0,1,2 → h01, h11, h21)
        //      col 2: [h[2], h[5], h[8]]  (r=0,1,2 → h02, h12, h22)
        let col0 = SIMD3<Float>(Float(h[0]), Float(h[3]), Float(h[6]))
        let col1 = SIMD3<Float>(Float(h[1]), Float(h[4]), Float(h[7]))
        let col2 = SIMD3<Float>(Float(h[2]), Float(h[5]), Float(h[8]))

        return simd_float3x3(columns: (col0, col1, col2))
    }
}
