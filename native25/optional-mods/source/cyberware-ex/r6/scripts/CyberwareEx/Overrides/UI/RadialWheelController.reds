@if(!ModuleExists("CyberarmOverhaul"))
@replaceMethod(RadialWheelController)
private final func GetValidCombatCyberware() -> InventoryItemData {
    let player = this.GetPlayer();
    let itemID = EquipmentSystem.GetData(player).GetActiveMeleeWare();
    let itemData: InventoryItemData;

    if ItemID.IsValid(itemID) {
        itemData = this.inventoryManager.GetItemDataFromIDInLoadout(itemID);
    }

    return itemData;
}
