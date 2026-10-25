module CyberwareEx

@if(ModuleExists("CyberwareEx.ExtendedMode"))
public func IsExtendedMode() -> Bool = true

@if(!ModuleExists("CyberwareEx.ExtendedMode"))
public func IsExtendedMode() -> Bool = false
