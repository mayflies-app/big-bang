import XCTest
@testable import BigBangCore

@MainActor private final class LoginItemFake: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var registrationResult: LoginItemStatus = .enabled
    var registerFailure: Error?
    var unregisterFailure: Error?
    var statusBeforeRegistrationFailure: LoginItemStatus?
    var registrationCalls = 0
    var unregistrationCalls = 0
    var settingsCalls = 0

    func register() throws {
        registrationCalls += 1
        if let registerFailure {
            if let statusBeforeRegistrationFailure { status = statusBeforeRegistrationFailure }
            throw registerFailure
        }
        status = registrationResult
    }
    func unregister() throws {
        unregistrationCalls += 1
        if let unregisterFailure { throw unregisterFailure }
        status = .disabled
    }
    func openSystemSettings() { settingsCalls += 1 }
}

final class LoginItemControllerTests: XCTestCase {
    func testFirstInstallNotFoundCanBeRegisteredForAValidApplicationBundle() {
        XCTAssertEqual(LoginItemSystemStatus.notFound.status(hasApplicationBundle: true), .disabled)
        XCTAssertEqual(LoginItemSystemStatus.notRegistered.status(hasApplicationBundle: true), .disabled)
        XCTAssertEqual(LoginItemSystemStatus.enabled.status(hasApplicationBundle: true), .enabled)
        XCTAssertEqual(LoginItemSystemStatus.requiresApproval.status(hasApplicationBundle: true), .requiresApproval)
    }

    func testUnbundledOrUnknownSystemServiceRemainsUnavailable() {
        for state in [LoginItemSystemStatus.enabled, .notRegistered, .notFound, .requiresApproval, .unknown] {
            XCTAssertEqual(state.status(hasApplicationBundle: false), .unavailable)
        }
        XCTAssertEqual(LoginItemSystemStatus.unknown.status(hasApplicationBundle: true), .unavailable)
    }

    @MainActor func testFirstInstallNotFoundUsesNormalRegistrationAndReadsApprovalResult() {
        let manager = LoginItemFake()
        manager.status = LoginItemSystemStatus.notFound.status(hasApplicationBundle: true)
        manager.registrationResult = .requiresApproval
        let controller = LoginItemController(manager: manager)
        XCTAssertTrue(controller.canToggle)
        controller.setEnabled(true)
        XCTAssertEqual(manager.registrationCalls, 1)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
    }

    @MainActor func testInitializationOnlyReadsAndToggleUsesSystemResult() {
        let manager = LoginItemFake()
        let controller = LoginItemController(manager: manager)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.canToggle)
        XCTAssertEqual(manager.registrationCalls, 0)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(manager.registrationCalls, 1)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(manager.unregistrationCalls, 1)
    }

    @MainActor func testRegistrationAwaitingApprovalKeepsToggleOnAndCanBeCancelled() {
        let manager = LoginItemFake()
        manager.registrationResult = .requiresApproval
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.canToggle)
        XCTAssertNil(controller.error)
        controller.openSystemSettings()
        XCTAssertEqual(manager.settingsCalls, 1)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertEqual(manager.unregistrationCalls, 1)
    }

    @MainActor func testRefreshReflectsChangesMadeInSystemSettings() {
        let manager = LoginItemFake()
        let controller = LoginItemController(manager: manager)
        manager.status = .enabled
        controller.refresh()
        XCTAssertTrue(controller.isEnabled)
        manager.status = .disabled
        controller.refresh()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(manager.registrationCalls, 0)
        XCTAssertEqual(manager.unregistrationCalls, 0)
    }

    @MainActor func testFailedRegistrationReportsActualDisabledState() {
        let manager = LoginItemFake()
        manager.registerFailure = ValidationError("mock registration failure")
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.error)
        manager.registerFailure = nil
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.error)
    }

    @MainActor func testFailedUnregistrationKeepsActualEnabledState() {
        let manager = LoginItemFake()
        manager.status = .enabled
        manager.unregisterFailure = ValidationError("mock unregistration failure")
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.error)
    }

    @MainActor func testFailureDoesNotUndoAnObservedSystemStateChange() {
        let manager = LoginItemFake()
        manager.registerFailure = ValidationError("mock registration failure")
        manager.statusBeforeRegistrationFailure = .requiresApproval
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.error)
    }

    @MainActor func testUnavailableServiceDisablesToggleAndExplainsWhy() {
        let manager = LoginItemFake()
        manager.status = .unavailable
        let controller = LoginItemController(manager: manager)
        XCTAssertFalse(controller.canToggle)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.error)
        controller.setEnabled(true)
        XCTAssertEqual(manager.registrationCalls, 0)
        XCTAssertEqual(controller.status, .unavailable)
    }

    @MainActor func testToggleRefreshesBeforeDecidingWhetherWriteIsNeeded() {
        let manager = LoginItemFake()
        let controller = LoginItemController(manager: manager)
        manager.status = .enabled
        controller.setEnabled(false)
        XCTAssertEqual(manager.unregistrationCalls, 1)
        XCTAssertFalse(controller.isEnabled)
        controller.setEnabled(false)
        XCTAssertEqual(manager.unregistrationCalls, 1)
    }

    @MainActor func testPreviewUsesAReversibleInMemoryService() {
        let controller = LoginItemController.preview()
        XCTAssertEqual(controller.status, .disabled)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        controller.openSystemSettings()
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
    }
}
