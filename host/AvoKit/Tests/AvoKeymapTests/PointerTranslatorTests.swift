import AvoProtocol
import Testing
@testable import AvoKeymap

@Suite struct PointerTranslatorTests {
    private func names(_ events: [TouchEvent]) -> [String] {
        events.map { e in "\(e.action):" + e.pointers.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: "|") }
    }

    @Test func clickIsATap() {
        var t = PointerTranslator(displayID: 1, width: 1000, height: 2000)
        #expect(names(t.mouseDown(x: 10, y: 20)) == ["down:10,20"])
        #expect(names(t.mouseDragged(x: 15, y: 25)) == ["move:15,25"])
        #expect(names(t.mouseUp(x: 15, y: 25)) == ["up:15,25"])
        #expect(t.mouseDragged(x: 1, y: 1).isEmpty) // no button: hover is ignored
    }

    @Test func trackpadScrollIsADragThatFollowsTheFingers() {
        var t = PointerTranslator(displayID: 1, width: 1000, height: 2000)
        #expect(names(t.scroll(phase: .began, x: 500, y: 1000, dx: 0, dy: -30)) == ["down:500,1000", "move:500,970"])
        #expect(names(t.scroll(phase: .changed, x: 500, y: 1000, dx: 0, dy: -40)) == ["move:500,930"])
        #expect(names(t.scroll(phase: .ended, x: 500, y: 1000, dx: 0, dy: 0)) == ["up:500,930"])
    }

    @Test func scrollStaysOnTheDisplay() {
        var t = PointerTranslator(displayID: 1, width: 100, height: 100)
        _ = t.scroll(phase: .began, x: 50, y: 5, dx: 0, dy: 0)
        #expect(names(t.scroll(phase: .changed, x: 0, y: 0, dx: 0, dy: -50)) == ["move:50,0"])
    }

    @Test func pinchUsesTwoFingersAroundTheCursor() {
        var t = PointerTranslator(displayID: 1, width: 1000, height: 1000)
        #expect(names(t.pinch(phase: .began, centerX: 500, centerY: 500, magnification: 0))
            == ["down:400,500", "pointerDown:400,500|600,500"])
        #expect(names(t.pinch(phase: .changed, centerX: 500, centerY: 500, magnification: 0.5)) == ["move:350,500|650,500"])
        #expect(names(t.pinch(phase: .ended, centerX: 500, centerY: 500, magnification: 0.5))
            == ["pointerUp:350,500|650,500", "up:350,500"])
    }

    @Test func newGestureCancelsTheOldOne() {
        var t = PointerTranslator(displayID: 1, width: 1000, height: 1000)
        _ = t.scroll(phase: .began, x: 10, y: 10, dx: 0, dy: 0)
        let events = names(t.mouseDown(x: 1, y: 1))
        #expect(events == ["cancel:10,10", "down:1,1"])
        #expect(names(t.cancel()) == ["cancel:0,0"])
        #expect(t.cancel().isEmpty)
    }
}
