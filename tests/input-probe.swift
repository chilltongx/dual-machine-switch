import CoreGraphics
import Foundation
let source=CGEventSource(stateID:.hidSystemState)
let down=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:true)!
down.type = .flagsChanged;down.flags = [.maskShift];down.post(tap:.cghidEventTap)
Thread.sleep(forTimeInterval:0.5)
let point=CGEvent(source:nil)!.location
let move=CGEvent(mouseEventSource:source,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:point.x+30,y:point.y+20),mouseButton:.left)!
move.setIntegerValueField(.mouseEventDeltaX,value:30);move.setIntegerValueField(.mouseEventDeltaY,value:20);move.post(tap:.cghidEventTap)
Thread.sleep(forTimeInterval:0.3)
let up=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:false)!
up.type = .flagsChanged;up.flags=[];up.post(tap:.cghidEventTap)
