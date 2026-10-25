import CyberwareEx.*

@wrapMethod(InventoryItemDisplayController)
public final func SetPerkRequiredCyberware(area: gamedataEquipmentArea) {
    wrappedMethod(area);

    let perkRecord = CyberwareHelper.GetRequiredPerkRecord(this.m_equipmentArea, this.m_slotIndex);
    if IsDefined(perkRecord) {
        inkImageRef.SetTexturePart(this.m_perkIcon, perkRecord.PerkIcon().AtlasPartName());
    }
}

@wrapMethod(InventoryItemDisplayController)
protected func UpdateLocked() {
    wrappedMethod();

    this.GetRootWidget().SetVisible(!this.m_isLocked || this.m_visibleWhenLocked);
}
