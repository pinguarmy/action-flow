import XCTest
@testable import ActionFlowCore

final class RuleSchedulerTests: XCTestCase {
    let app = ExecutionContext(processIdentifier: 100, bundleIdentifier: "com.example.Editor")
    func rule(_ name: String = "Test", kind: TriggerKind = .shortcut) -> AutomationRule {
        AutomationRule(name:name, enabled:true, trigger:Trigger(kind:kind, keyCode:0,modifiers:[.command],intervalSeconds:2,appBundleIdentifier:"com.example.Editor"), actions:[AutomationAction(kind:.delay,delaySeconds:0)])
    }
    func testAutomaticEligibilityFailsClosed() {
        XCTAssertTrue(RuleScheduler.canAutomaticallyRun(context:app,editorBundleIdentifier:"io.github.pinguarmy.actionflow",automationEnabled:true,isRecording:false,isPreparingManualRun:false))
        for context in [ExecutionContext(processIdentifier:nil,bundleIdentifier:"com.example.Editor"),ExecutionContext(processIdentifier:0,bundleIdentifier:"com.example.Editor"),ExecutionContext(processIdentifier:1,bundleIdentifier:""),ExecutionContext(processIdentifier:1,bundleIdentifier:"ORG.ACTIONFLOW.APP")] {
            XCTAssertFalse(RuleScheduler.canAutomaticallyRun(context:context,editorBundleIdentifier:"io.github.pinguarmy.actionflow",automationEnabled:true,isRecording:false,isPreparingManualRun:false))
        }
        XCTAssertFalse(RuleScheduler.canAutomaticallyRun(context:app,editorBundleIdentifier:"io.github.pinguarmy.actionflow",automationEnabled:true,isRecording:true,isPreparingManualRun:false))
        XCTAssertFalse(RuleScheduler.canAutomaticallyRun(context:app,editorBundleIdentifier:"io.github.pinguarmy.actionflow",automationEnabled:true,isRecording:false,isPreparingManualRun:true))
    }
    func testShortcutMatchingCooldownAndReset() {
        var scheduler=RuleScheduler();var r=rule();r.cooldown=1
        let signal=TriggerSignal(kind:.shortcut,keyCode:0,modifiers:[.command])
        XCTAssertEqual(scheduler.candidates(for:signal,rules:[r],context:app,now:10).map(\.id),[r.id])
        XCTAssertTrue(scheduler.candidates(for:signal,rules:[r],context:app,now:10.5).isEmpty)
        XCTAssertEqual(scheduler.candidates(for:signal,rules:[r],context:app,now:11).count,1)
        scheduler.reset()
        XCTAssertEqual(scheduler.candidates(for:signal,rules:[r],context:app,now:11).count,1)
        XCTAssertTrue(scheduler.candidates(for:TriggerSignal(kind:.shortcut,keyCode:0,modifiers:[.option]),rules:[r],context:app,now:20).isEmpty)
    }
    func testIntervalsDoNotReplayMissedPeriodsOrFireImmediately() {
        var scheduler=RuleScheduler();let r=rule(kind:.interval)
        XCTAssertTrue(scheduler.intervalCandidates(rules:[r],context:app,now:0).isEmpty)
        XCTAssertEqual(scheduler.intervalCandidates(rules:[r],context:app,now:100).count,1)
        XCTAssertTrue(scheduler.intervalCandidates(rules:[r],context:app,now:100.1).isEmpty)
    }
    func testAppActivationUsesNormalizedIdentity() {
        var scheduler=RuleScheduler();let r=rule(kind:.appActivated)
        XCTAssertEqual(scheduler.candidates(for:TriggerSignal(kind:.appActivated,appBundleIdentifier:"COM.EXAMPLE.EDITOR"),rules:[r],context:app,now:1).count,1)
        XCTAssertTrue(scheduler.candidates(for:TriggerSignal(kind:.appActivated,appBundleIdentifier:"com.other.App"),rules:[r],context:app,now:10).isEmpty)
    }
    func testQueueIsFIFOAndDeduplicated() {
        var queue=RuleExecutionQueue(capacity:2);let a=rule("A"),b=rule("B"),c=rule("C")
        XCTAssertTrue(queue.append(a,context:app,runningRuleID:nil))
        XCTAssertFalse(queue.append(a,context:app,runningRuleID:nil))
        XCTAssertTrue(queue.append(b,context:app,runningRuleID:nil))
        XCTAssertFalse(queue.append(c,context:app,runningRuleID:nil))
        XCTAssertEqual(queue.next(rules:[a,b,c],context:app)?.id,a.id)
        XCTAssertEqual(queue.next(rules:[a,b,c],context:app)?.id,b.id)
    }
    func testQueueRejectsChangedProcessEvenWithSameBundle() {
        var queue=RuleExecutionQueue();let r=rule()
        queue.append(r,context:app,runningRuleID:nil)
        XCTAssertNil(queue.next(rules:[r],context:ExecutionContext(processIdentifier:101,bundleIdentifier:app.bundleIdentifier)))
        XCTAssertEqual(queue.count,0)
    }
    func testQueueSkipsDeletedDisabledAndRunningRules() {
        var queue=RuleExecutionQueue();var r=rule()
        XCTAssertFalse(queue.append(r,context:app,runningRuleID:r.id))
        queue.append(r,context:app,runningRuleID:nil);r.enabled=false
        XCTAssertNil(queue.next(rules:[r],context:app))
        r.enabled=true;queue.append(r,context:app,runningRuleID:nil)
        XCTAssertNil(queue.next(rules:[],context:app))
    }
}
