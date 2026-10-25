module CyberwareEx

@if(ModuleExists("CyberwareEx.OverrideMode"))
public func IsOverrideMode() -> Bool = true

@if(!ModuleExists("CyberwareEx.OverrideMode"))
public func IsOverrideMode() -> Bool = false
