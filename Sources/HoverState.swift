import Foundation

struct HoverState {
    private var outsideSince: TimeInterval?
    private var wasOnIcon = false
    private var suppressIcon = false

    mutating func dismissed() {
        outsideSince = nil
        suppressIcon = true
    }

    mutating func reset() {
        outsideSince = nil
        wasOnIcon = false
        suppressIcon = false
    }

    mutating func update(icon: Bool, panel: Bool, visible: Bool, delay: Int, now: TimeInterval) -> Int {
        if !icon { suppressIcon = false }
        let enteredIcon = icon && !wasOnIcon
        wasOnIcon = icon
        guard delay > 0 else { outsideSince = nil; return 0 }
        if icon || panel {
            outsideSince = nil
            return enteredIcon && !suppressIcon && !visible ? 1 : 0
        }
        guard visible else { outsideSince = nil; return 0 }
        if outsideSince == nil { outsideSince = now }
        if now - outsideSince! >= Double(delay) { outsideSince = nil; return -1 }
        return 0
    }
}
