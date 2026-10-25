@replaceMethod(ChargedHotkeyItemCyberwareController)
protected func UpdateCurrentItem() {
    let cyberwareType = this.GetRootWidget().GetName();

    let playerData = this.m_equipmentSystem.GetPlayerData(this.GetPlayerControlledObject());
    let activeItemID = playerData.GetTaggedItem(gamedataEquipmentArea.SystemReplacementCW, cyberwareType);
    
    if ItemID.IsValid(activeItemID) {
        let previousItem = this.m_currentItem;
        
        this.m_currentItem = this.m_inventoryManager.GetInventoryItemDataFromItemID(activeItemID);
        this.m_currentItem.Quantity = 0;

        this.m_hotkeyItemController.Setup(this.m_currentItem, ItemDisplayContext.DPAD_RADIAL);
        this.ResolveState();
        
        if previousItem.ID != this.m_currentItem.ID {
            this.UpdateStatListener();
            this.UpdateChargeValue(
                this.GetStatPoolCurrentValue(this.m_currentStatPoolType, true),
                this.GetStatPoolMaxPoints(this.m_currentStatPoolType) / 100.00,
                false
            );
        }

        switch this.GetItemType(this.m_currentItem.ID, n"None") {
            case this.c_cyberdeckKey:
                this.GetRootWidget().SetVisible(this.IsCyberdeckOverloadPerkPresent());
                break;
            case this.c_sandevistanKey:
                this.UpdateSandevistanVisibility();
                break;
            case this.c_berserkKey:
                this.GetRootWidget().SetVisible(Equals(PlayerPuppet.GetCurrentVehicleState(this.GetPlayer()), gamePSMVehicle.Default));
                break;
            case this.c_capacityBoosterKey:
                this.GetRootWidget().SetVisible(false);
                break;
            default:
                this.GetRootWidget().SetVisible(true);
        }
    } else {
        this.m_currentItem = this.m_inventoryManager.GetInventoryItemDataFromItemID(ItemID.None());
        this.m_hotkeyItemController.Setup(this.m_currentItem, ItemDisplayContext.DPAD_RADIAL);
        this.GetRootWidget().SetVisible(false);
    }
}

//@replaceMethod(ChargedHotkeyItemCyberwareController)
//private final func IsCyberdeckOverloadPerkPresent() -> Bool {
//    return true;
//}
