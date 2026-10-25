@replaceMethod(CyberwareInventoryMiniGrid)
public final func GetSlotToEquipe(itemID: ItemID) -> Int32 {
    let cyberwareType = TweakDBInterface.GetCName(ItemID.GetTDBID(itemID) + t".cyberwareType", n"None");
    let slotIndex = ArraySize(this.m_gridData) - 1;
    let emptyIndex = -1;
    while slotIndex >= 0 {
        if !this.m_gridData[slotIndex].IsLocked() {
            if !IsDefined(this.m_gridData[slotIndex].GetUIInventoryItem()) {
                emptyIndex = this.m_gridData[slotIndex].GetSlotIndex();
            } else {
                let equippedType = TweakDBInterface.GetCNameDefault(this.m_gridData[slotIndex].GetUIInventoryItem().GetTweakDBID() + t".cyberwareType");
                if Equals(cyberwareType, equippedType) {
                    emptyIndex = this.m_gridData[slotIndex].GetSlotIndex();
                    break;
                }
            }
        }
        slotIndex -= 1;
    }
    return emptyIndex != -1 ? emptyIndex : (this.m_selectedSlotIndex != -1 ? this.m_selectedSlotIndex : 0);
}
