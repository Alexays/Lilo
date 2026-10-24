import XCTest
@testable import Lilo

final class FolderLockKeychainTests: XCTestCase {
    private let folderId = UUID()

    override func tearDown() {
        FolderLockKeychain.remove(folderId: folderId)
        super.tearDown()
    }

    func testVerifyAcceptsOnlyThePasswordThatWasSet() {
        XCTAssertTrue(FolderLockKeychain.setPassword("correct horse", folderId: folderId))

        XCTAssertTrue(FolderLockKeychain.verify("correct horse", folderId: folderId))
        XCTAssertFalse(FolderLockKeychain.verify("correct hors", folderId: folderId))
        XCTAssertFalse(FolderLockKeychain.verify("", folderId: folderId))
    }

    func testSettingAgainReplacesThePassword() {
        XCTAssertTrue(FolderLockKeychain.setPassword("first", folderId: folderId))
        XCTAssertTrue(FolderLockKeychain.setPassword("second", folderId: folderId))

        XCTAssertFalse(FolderLockKeychain.verify("first", folderId: folderId))
        XCTAssertTrue(FolderLockKeychain.verify("second", folderId: folderId))
    }

    func testRemoveForgetsThePassword() {
        XCTAssertTrue(FolderLockKeychain.setPassword("secret", folderId: folderId))
        FolderLockKeychain.remove(folderId: folderId)

        XCTAssertFalse(FolderLockKeychain.verify("secret", folderId: folderId))
    }

    func testEmptyPasswordIsRefused() {
        XCTAssertFalse(FolderLockKeychain.setPassword("", folderId: folderId))
        XCTAssertFalse(FolderLockKeychain.verify("", folderId: folderId))
    }
}
