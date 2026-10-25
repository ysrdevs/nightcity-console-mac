module CyberwareEx

public class OverrideState {
    public let areaType: gamedataEquipmentArea;
    public let areaIndex: Int32;
    public let currentSlots: Int32;
    public let defaultSlots: Int32;
    public let maxSlots: Int32;
    public let isOverridable: Bool;
    public let canBuyOverride: Bool;
    public let canBuyReset: Bool;
}

public class OverrideManager {
    private let m_overrides: array<OverrideArea>;
    private let m_playerData: ref<EquipmentSystemPlayerData>;

    public func Initialize(playerData: ref<EquipmentSystemPlayerData>) {
        this.m_playerData = playerData;
        this.m_overrides = OverrideConfig.SlotOverrides();

        let i = 0;
        while i < ArraySize(this.m_overrides) {
            let areaRecord = this.m_playerData.GetEquipAreaRecordByType(this.m_overrides[i].areaType);
            this.m_overrides[i].defaultSlots = areaRecord.GetEquipSlotsCount();
            i += 1;
        }
    }

    public func GetOverrideState(areaType: gamedataEquipmentArea) -> ref<OverrideState> {
        let overrideState = new OverrideState();
        overrideState.areaType = areaType;
        overrideState.areaIndex = this.GetEquipAreaIndex(areaType);
        overrideState.currentSlots = this.GetEquipAreaNumberOfSlots(areaType);

        let overrideArea = this.GetOverrideArea(areaType);
        if OverrideArea.IsValid(overrideArea) {
            overrideState.defaultSlots = overrideArea.defaultSlots;
            overrideState.maxSlots = overrideArea.maxSlots;
            overrideState.isOverridable = true;

            let playerMoney = GameInstance.GetTransactionSystem(this.m_playerData.m_owner.GetGame())
                .GetItemQuantity(this.m_playerData.m_owner, MarketSystem.Money());

            overrideState.canBuyOverride = (playerMoney >= OverrideConfig.UpgradePrice());
            overrideState.canBuyReset = (playerMoney >= OverrideConfig.ResetPrice());
        }

        return overrideState;
    }

    public func UpgradeSlot(areaType: gamedataEquipmentArea, opt free: Bool, opt vendor: wref<GameObject>) -> Bool {
        let overrideState = this.GetOverrideState(areaType);

        if !overrideState.isOverridable || overrideState.currentSlots == overrideState.maxSlots {
            return false;
        }

        if !overrideState.canBuyOverride && !free {
            return false;
        }

        let newSlotIndex = overrideState.currentSlots;
        let equipSlotID = CyberwareHelper.CreateEquipSlotRecord(areaType, newSlotIndex);

        ArrayResize(this.m_playerData.m_equipment.equipAreas[overrideState.areaIndex].equipSlots, overrideState.currentSlots + 1);

        this.m_playerData.InitializeEquipSlotFromRecord(TweakDBInterface.GetEquipSlotRecord(equipSlotID),
            this.m_playerData.m_equipment.equipAreas[overrideState.areaIndex].equipSlots[newSlotIndex]);

        if !free {
            let transactionSystem = GameInstance.GetTransactionSystem(this.m_playerData.m_owner.GetGame());
            if IsDefined(vendor) {
                transactionSystem.TransferItem(this.m_playerData.m_owner, vendor, MarketSystem.Money(), OverrideConfig.UpgradePrice());
            } else {
                transactionSystem.RemoveItem(this.m_playerData.m_owner, MarketSystem.Money(), OverrideConfig.UpgradePrice());
            }
        }

        return true;
    }

    public func ResetSlot(areaType: gamedataEquipmentArea, opt free: Bool, opt vendor: wref<GameObject>) -> Bool {
        let overrideState = this.GetOverrideState(areaType);

        if !overrideState.isOverridable || overrideState.currentSlots == overrideState.defaultSlots {
            return false;
        }

        if !overrideState.canBuyReset && !free {
            return false;
        }

        let slotIndex = overrideState.defaultSlots + 1;
        while slotIndex <= overrideState.currentSlots {
            if ItemID.IsValid(this.m_playerData.m_equipment.equipAreas[overrideState.areaIndex].equipSlots[slotIndex].itemID) {
                this.m_playerData.UnequipItem(overrideState.areaIndex, slotIndex);
            }
            slotIndex += 1;
        }

        ArrayResize(this.m_playerData.m_equipment.equipAreas[overrideState.areaIndex].equipSlots, overrideState.defaultSlots);

        if !free {
            let transactionSystem = GameInstance.GetTransactionSystem(this.m_playerData.m_owner.GetGame());
            if IsDefined(vendor) {
                transactionSystem.TransferItem(this.m_playerData.m_owner, vendor, MarketSystem.Money(), OverrideConfig.ResetPrice());
            } else {
                transactionSystem.RemoveItem(this.m_playerData.m_owner, MarketSystem.Money(), OverrideConfig.ResetPrice());
            }
        }

        return true;
    }

    private func GetOverrideArea(areaType: gamedataEquipmentArea) -> OverrideArea {
        for slot in this.m_overrides {
            if Equals(slot.areaType, areaType) {
                return slot;
            }
        }

        return OverrideArea.None();
    }

    private func GetEquipAreaIndex(areaType: gamedataEquipmentArea) -> Int32 {
        let i = 0;
        while i < ArraySize(this.m_playerData.m_equipment.equipAreas) {
            if Equals(this.m_playerData.m_equipment.equipAreas[i].areaType, areaType) {
                return i;
            }
            i += 1;
        }
        return -1;
    }

    private func GetEquipAreaNumberOfSlots(areaType: gamedataEquipmentArea) -> Int32 {
        let i = 0;
        while i < ArraySize(this.m_playerData.m_equipment.equipAreas) {
            if Equals(this.m_playerData.m_equipment.equipAreas[i].areaType, areaType) {
                return ArraySize(this.m_playerData.m_equipment.equipAreas[i].equipSlots);
            }
            i += 1;
        }
        return -1;
    }
}
