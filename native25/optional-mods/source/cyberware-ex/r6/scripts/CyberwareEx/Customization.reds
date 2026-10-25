module CyberwareEx

@if(ModuleExists("CyberwareEx.Customization"))
import CyberwareEx.Customization.*

@if(ModuleExists("CyberwareEx.Customization"))
public func IsCustomMode() -> Bool = true

@if(ModuleExists("CyberwareEx.Customization"))
public func GetCustomSlotExpansions() -> array<ExpansionArea> = UserConfig.SlotExpansions()

@if(ModuleExists("CyberwareEx.Customization"))
public func GetCustomSlotOverrides() -> array<OverrideArea> = UserConfig.SlotOverrides()

@if(ModuleExists("CyberwareEx.Customization"))
public func GetCustomUpgradePrice() -> Int32 = UserConfig.UpgradePrice()

@if(ModuleExists("CyberwareEx.Customization"))
public func GetCustomResetPrice() -> Int32 = UserConfig.ResetPrice()

@if(ModuleExists("CyberwareEx.Customization"))
public func IsCombinedAbilityMode() -> Bool = UserConfig.CombinedAbilityMode()

@if(!ModuleExists("CyberwareEx.Customization"))
public func IsCustomMode() -> Bool = false

@if(!ModuleExists("CyberwareEx.Customization"))
public func GetCustomSlotExpansions() -> array<ExpansionArea> = DefaultConfig.SlotExpansions()

@if(!ModuleExists("CyberwareEx.Customization"))
public func GetCustomSlotOverrides() -> array<OverrideArea> = DefaultConfig.SlotOverrides()

@if(!ModuleExists("CyberwareEx.Customization"))
public func GetCustomUpgradePrice() -> Int32 = DefaultConfig.UpgradePrice()

@if(!ModuleExists("CyberwareEx.Customization"))
public func GetCustomResetPrice() -> Int32 = DefaultConfig.ResetPrice()

@if(!ModuleExists("CyberwareEx.Customization"))
public func IsCombinedAbilityMode() -> Bool = DefaultConfig.CombinedAbilityMode()

public abstract class DefaultConfig {
    public static func SlotExpansions() -> array<ExpansionArea> = CyberwareConfig.DefaultSlotExpansions()
    public static func SlotOverrides() -> array<OverrideArea> = OverrideConfig.DefaultSlotOverrides()
    public static func UpgradePrice() -> Int32 = OverrideConfig.DefaultUpgradePrice()
    public static func ResetPrice() -> Int32 = OverrideConfig.DefaultResetPrice()
    public static func CombinedAbilityMode() -> Bool = false
}
