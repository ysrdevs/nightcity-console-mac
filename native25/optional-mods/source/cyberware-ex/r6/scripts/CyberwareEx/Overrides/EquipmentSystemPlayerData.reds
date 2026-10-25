import CyberwareEx.*

@addMethod(EquipmentSystemPlayerData)
public func HasTaggedItem(equipArea: gamedataEquipmentArea, requiredTag: CName) -> Bool {
    return ItemID.IsValid(this.GetTaggedItem(equipArea, [requiredTag]));
}

@addMethod(EquipmentSystemPlayerData)
public func GetTaggedItem(equipArea: gamedataEquipmentArea, requiredTag: CName) -> ItemID {
    return this.GetTaggedItem(equipArea, [requiredTag]);
}

@addMethod(EquipmentSystemPlayerData)
public func GetTaggedItem(equipArea: gamedataEquipmentArea, requiredTags: array<CName>) -> ItemID {
    let equipAreaIndex = this.GetEquipAreaIndex(equipArea);
    let numSlots = ArraySize(this.m_equipment.equipAreas[equipAreaIndex].equipSlots);
    let slotIndex = 0;

    while slotIndex < numSlots {
        let itemID = this.m_equipment.equipAreas[equipAreaIndex].equipSlots[slotIndex].itemID;

        if ItemID.IsValid(itemID) && this.CheckTagsInItem(itemID, requiredTags) {
            return itemID;
        }

        slotIndex += 1;
    }

    return ItemID.None();
}

@addMethod(EquipmentSystemPlayerData)
public func ApplyAreaPowerUps(equipArea: gamedataEquipmentArea) {
    let equipAreaIndex = this.GetEquipAreaIndex(equipArea);
    let numSlots = ArraySize(this.m_equipment.equipAreas[equipAreaIndex].equipSlots);
    let slotIndex = 0;

    while slotIndex < numSlots {
        PowerUpCyberwareEffector.PowerUpCyberwareInSlot(this.m_owner, equipArea, slotIndex);
        slotIndex += 1;
    }
}

// Overrides how the active item is resolved for the system replacement slot so that
// it returns a Cyberdeck installed in any slot, not just in the first.
@wrapMethod(EquipmentSystemPlayerData)
public final const func GetActiveItem(equipArea: gamedataEquipmentArea) -> ItemID {
    if Equals(equipArea, gamedataEquipmentArea.SystemReplacementCW) {
        return this.GetTaggedItem(equipArea, n"Cyberdeck");
    }

    return wrappedMethod(equipArea);
}

// Allows multiple cyberware with the same effects.
@wrapMethod(EquipmentSystemPlayerData)
private final func UnequipItem(equipAreaIndex: Int32, slotIndex: Int32, opt forceRemove: Bool) {
    wrappedMethod(equipAreaIndex, slotIndex, forceRemove);

    switch this.m_equipment.equipAreas[equipAreaIndex].areaType {
        case gamedataEquipmentArea.EyesCW:
        case gamedataEquipmentArea.LegsCW:
        case gamedataEquipmentArea.SystemReplacementCW:
            let slotIndex = 0;
            let numberOfSlots = ArraySize(this.m_equipment.equipAreas[equipAreaIndex].equipSlots);
            while slotIndex < numberOfSlots {
                let itemID = this.m_equipment.equipAreas[equipAreaIndex].equipSlots[slotIndex].itemID;
                if ItemID.IsValid(itemID) {
                    this.RemoveEquipGLPs(itemID);
                    this.ApplyEquipGLPs(itemID);
                }
                slotIndex += 1;
            }
            break;
    }
}

@replaceMethod(EquipmentSystemPlayerData)
public final func AssignItemToHotkey(newID: ItemID, hotkey: EHotkey) {
    if Equals(hotkey, EHotkey.INVALID) {
        return;
    }

    let oldID = this.m_hotkeys[EnumInt(hotkey)].GetItemID();
    if newID == oldID {
        if Equals(hotkey, EHotkey.LBRB) {
            this.SyncHotkeyData(hotkey);
        }
        return;
    }

    let transactionSystem = GameInstance.GetTransactionSystem(this.m_owner.GetGame());

    let oldCategory = RPGManager.GetItemCategory(oldID);
    if NotEquals(oldCategory, gamedataItemCategory.Cyberware) {
        transactionSystem.OnItemRemovedFromEquipmentSlot(this.m_owner, oldID);
    }
    if Equals(oldCategory, gamedataItemCategory.Consumable) {
        this.RemoveEquipGLPs(oldID);
    }

    this.m_hotkeys[EnumInt(hotkey)].StoreItem(newID);

    let newCategory = RPGManager.GetItemCategory(newID);
    if NotEquals(newCategory, gamedataItemCategory.Cyberware) {
        transactionSystem.OnItemAddedToEquipmentSlot(this.m_owner, newID);
    }
    if Equals(newCategory, gamedataItemCategory.Consumable) {
        this.ApplyEquipGLPs(newID);
    }

    this.SyncHotkeyData(hotkey);
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(EquipmentSystemPlayerData)
private final const func IsSlotLocked(slot: SEquipSlot, out visibleWhenLocked: Bool) -> Bool {
    if !slot.visibleWhenLocked {
        return wrappedMethod(slot, visibleWhenLocked);
    }
    visibleWhenLocked = true;
    return false;
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(EquipmentSystemPlayerData)
private final func InitializeEquipmentArea(equipAreaRecord: ref<EquipmentArea_Record>, out equipArea: SEquipArea) {
    let equipSlotRecords: array<wref<EquipSlot_Record>>;
    equipAreaRecord.EquipSlots(equipSlotRecords);

    if CyberwareHelper.IsCyberwareArea(equipArea.areaType) {
        let numberOfRecords = ArraySize(equipSlotRecords);
        let numberOfSlots = ArraySize(equipArea.equipSlots);
        if numberOfSlots > numberOfRecords {
            let slotIndex = numberOfRecords;
            while slotIndex < numberOfSlots {
                let equipSlotID = CyberwareHelper.CreateEquipSlotRecord(equipArea.areaType, slotIndex);
                ArrayPush(equipSlotRecords, TweakDBInterface.GetEquipSlotRecord(equipSlotID));
                slotIndex += 1;
            }
        }
    }

    this.InitializeEquipSlotsFromRecords(equipSlotRecords, equipArea.equipSlots);
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(EquipmentSystemPlayerData)
private final func InitializeEquipSlotsFromRecords(slotRecords: array<wref<EquipSlot_Record>>, out equipSlots: array<SEquipSlot>) {
    let numberOfRecords = ArraySize(slotRecords);
    let numberOfSlots = ArraySize(equipSlots);
    let finalSize = Max(numberOfRecords, numberOfSlots);
    let i = 0;
    while i < finalSize {
        if i < numberOfRecords {
            let equipSlot: SEquipSlot;
            this.InitializeEquipSlotFromRecord(slotRecords[i], equipSlot);
            if i < numberOfSlots {
                if !IsDefined(equipSlot.unlockPrereq) || equipSlot.visibleWhenLocked || equipSlot.unlockPrereq.IsFulfilled(this.m_owner.GetGame(), this.m_owner) {
                    equipSlot.itemID = equipSlots[i].itemID;
                }
                equipSlots[i] = equipSlot;
            } else {
                ArrayPush(equipSlots, equipSlot);
            }
        } else {
            this.InitializeEquipSlotFromRecord(TweakDBInterface.GetEquipSlotRecord(t"EquipmentArea.SimpleEquipSlot"), equipSlots[i]);
        }
        i += 1;
    }
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(EquipmentSystemPlayerData)
private final func InitializeEquipSlotsFromRecords(slotRecords: array<wref<EquipSlot_Record>>, out equipSlots: array<SEquipSlot>) {
    wrappedMethod(slotRecords, equipSlots);
    ArrayResize(equipSlots, ArraySize(slotRecords));
}

@if(!ModuleExists("CyberarmOverhaul"))
@wrapMethod(EquipmentSystemPlayerData)
private final const func UpdateQuickWheel() {
    wrappedMethod();

    let i = 0;
    while i < ArraySize(this.m_hotkeys) {
        let itemID = this.m_hotkeys[i].GetItemID();
        if ItemID.IsValid(itemID) {
            if this.CheckTagsInItem(itemID, [n"ProjectileLauncher"]) {
                if !this.IsEquipped(itemID) {
                    this.AssignNextValidItemToHotkey(itemID);
                }
                break;
            }
        }
        i += 1;
    }
}

@if(!ModuleExists("CyberarmOverhaul"))
@replaceMethod(EquipmentSystemPlayerData)
public final static func UpdateArmSlot(owner: ref<PlayerPuppet>, itemToDraw: ItemID, equipHolsteredItem: Bool) {
    if !IsDefined(owner) || !ItemID.IsValid(itemToDraw) || owner.IsJohnnyReplacer() {
      return;
    }

    let equipmentData = EquipmentSystem.GetData(owner);

    if !IsDefined(equipmentData) {
      return;
    }

    let transactionSystem = GameInstance.GetTransactionSystem(owner.GetGame());
    let rightWeaponID = transactionSystem.GetItemInSlot(owner, t"AttachmentSlots.WeaponRight").GetItemID();
    let leftWeaponID = transactionSystem.GetItemInSlot(owner, t"AttachmentSlots.WeaponLeft").GetItemID();

    let cyberArmsInUse = ItemID.IsValid(rightWeaponID) && TweakDBInterface.GetItemRecord(ItemID.GetTDBID(rightWeaponID)).TagsContains(n"Meleeware");
    let launcherInUse = ItemID.IsValid(leftWeaponID) && TweakDBInterface.GetItemRecord(ItemID.GetTDBID(leftWeaponID)).TagsContains(n"ProjectileLauncher");

    let meleeWareID = ItemID.None();
    let slotIndex = 0;
    let equipAreaIndex = equipmentData.GetEquipAreaIndex(gamedataEquipmentArea.ArmsCW);
    let numberOfSlots = ArraySize(equipmentData.m_equipment.equipAreas[equipAreaIndex].equipSlots);
    while slotIndex < numberOfSlots {
        let itemID = equipmentData.m_equipment.equipAreas[equipAreaIndex].equipSlots[slotIndex].itemID;
        if ItemID.IsValid(itemID) {
            meleeWareID = itemID;
            let itemRecord = TweakDBInterface.GetItemRecord(ItemID.GetTDBID(itemID));
            if !itemRecord.TagsContains(n"ProjectileLauncher") {
                break;
            }
        }
        slotIndex += 1;
    }

    if !ItemID.IsValid(meleeWareID) {
        meleeWareID = equipmentData.GetBaseFistsItemID();
    }

    if !launcherInUse && !cyberArmsInUse {
        let holsteredArmsID = ItemID.CreateQuery(TweakDBInterface.GetWeaponItemRecord(ItemID.GetTDBID(meleeWareID)).HolsteredItem().GetID());

        if !transactionSystem.HasItem(owner, holsteredArmsID) {
            transactionSystem.GiveItem(owner, holsteredArmsID, 1);
        }

        EquipmentSystemPlayerData.ForceQualityAndDuplicateStatsShard(owner, meleeWareID, holsteredArmsID);

        if !equipmentData.IsEquipped(holsteredArmsID) {
            equipmentData.EquipItem(holsteredArmsID, false, false);
        }
    } else {
        equipmentData.UnequipItem(equipmentData.GetEquipAreaIndex(gamedataEquipmentArea.RightArm), 0, true);
    }
}
