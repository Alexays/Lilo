import Security
import XCTest
@testable import Lilo

final class CertificateRejectionReasonTests: XCTestCase {
    // Self-signed, CN and SAN example.com.
    private static let selfSigned = "MIIDBDCCAeygAwIBAgIUWX8yWAGJrNkshASupYYvf0o97KMwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLZXhhbXBsZS5jb20wHhcNMjYxMDI3MTQxNjM3WhcNMjcxMDI3MTQxNjM3WjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANYfBQDM6hR1b1hPNXizmqdR0L8T+e2hEL7v+pLeZhgwdUU0i/m5R3ZGrP4RBSbWxcieG//3klzRBGhF5G8k1dHSLzVgu93IgEZzG0jTSl8GCRr+q9VvIp7VQkfx+9bWwGziWOxGM2S0wj6ThNCQQaorwMtH80GYzTNrCLVdSyOG4+FmJdpxun+oqChu662X44/jRkvqFgtAXd6stX0+GeLxPBQ2/PjCajamnh1uFW6rm9dGwaRWXojXPdEaS87eFz0aANrTKzwrgeHUPqVwnOqg/uMbFNazN95+2EuTuIGoHaVktbpW/oZ7yP9lHCrytebAV12/m6Jj75gVy/j3SD8CAwEAAaNKMEgwHQYDVR0OBBYEFBuFqUJtRBdcYB3uSDkyMMojWtKlMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILZXhhbXBsZS5jb20wDQYJKoZIhvcNAQELBQADggEBAAdRuBVXBBwMLaVNK4PZuw8V4dQiRG8FeSd+eL9IVQW+dValHOEjllAkzuNyYNSRx45OeKWC7ZWS9/5ZkemtZOaJGbb9HzWbDNt53x3hqXMfrr0jYIKrXYn+M0c9S0WOtsGE4oJ0vbrLvDQnifXT1+RUrUyAcC0Bn4l8e8ug3L/27adK2VI32QKWTmTcPjwzL3dCyXJNPLDySsL4VWoGlhVdxzXH/7avf/J+7AlrjCHacCuwJx5/qpVOtID/JxUD+7FmlsDrD6Sfp1ZAtHpSALqRAcrdNdPy1LBzU1Bub5hCpVnO2YTB1ZcfcpVTgOGPCa6o0gtEuwIAFpqqaw7kbbk="

    private func selfSignedTrust() throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: Self.selfSigned)) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "example.com" as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    func testUntrustedCertificateNamesTheRejectedCertificate() throws {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let reason = try XCTUnwrap(MainWindowController.certificateRejectionReason(error, trust: try selfSignedTrust()))
        XCTAssertTrue(reason.contains("example.com"), reason)
    }

    func testOtherErrorsHaveNoCertificateReason() throws {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertNil(MainWindowController.certificateRejectionReason(error, trust: try selfSignedTrust()))
    }
}
