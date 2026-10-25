module CyberwareEx

public class CyberwareHelper {
    public static func GetSlotRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> wref<EquipSlot_Record> {
        let equipAreaID = TDBID.Create("EquipmentArea." + ToString(equipArea));
        let equipArea = TweakDBInterface.GetEquipmentAreaRecord(equipAreaID);
        return equipArea.GetEquipSlotsItem(slotIndex);
    }

    public static func GetPrereqRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> wref<IPrereq_Record> {
        let equipSlot = CyberwareHelper.GetSlotRecord(equipArea, slotIndex);
        return equipSlot.UnlockPrereqRecord();
    }

    public static func GetPerkPrereqRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> wref<PlayerIsNewPerkBoughtPrereq_Record> {
        let equipSlot = CyberwareHelper.GetSlotRecord(equipArea, slotIndex);
        return equipSlot.UnlockPrereqRecord() as PlayerIsNewPerkBoughtPrereq_Record;
    }

    public static func GetRequiredPerkAbility(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> gamedataNewPerkType {
        let perkPrereq = CyberwareHelper.GetPerkPrereqRecord(equipArea, slotIndex);
        return IsDefined(perkPrereq)
            ? IntEnum<gamedataNewPerkType>(Cast<Int32>(EnumValueFromString("gamedataNewPerkType", perkPrereq.PerkType())))
            : gamedataNewPerkType.Invalid;
    }

    public static func GetRequiredPerkRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> wref<NewPerk_Record> {
        let perkPrereq = CyberwareHelper.GetPerkPrereqRecord(equipArea, slotIndex);
        if IsDefined(perkPrereq) {
            let perkID = TDBID.Create("NewPerks." + perkPrereq.PerkType());
            return TweakDBInterface.GetNewPerkRecord(perkID);
        } else {
            return null;
        }
    }

    public static func GetRequiredPerkType(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> gamedataNewPerkType {
        let perkRecord = CyberwareHelper.GetRequiredPerkRecord(equipArea, slotIndex);
        return IsDefined(perkRecord) ? perkRecord.Type() : gamedataNewPerkType.Invalid;

        //let perkPrereq = CyberwareHelper.GetPerkPrereqRecord(equipArea, slotIndex);
        //return IsDefined(perkPrereq)
        //    ? IntEnum<gamedataNewPerkType>(Cast<Int32>(EnumValueFromString("gamedataNewPerkType", perkPrereq.PerkType())))
        //    : gamedataNewPerkType.Invalid;
    }

    public static func GetRequiredPerkStatType(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> gamedataStatType {
        let perkRecord = CyberwareHelper.GetRequiredPerkRecord(equipArea, slotIndex);
        return IsDefined(perkRecord) ? perkRecord.Attribute().Attribute().StatType() : gamedataStatType.Invalid;
    }

    public static func GetRequiredPerkLevel(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> Int32 {
        let perkPrereq = CyberwareHelper.GetPerkPrereqRecord(equipArea, slotIndex);
        return IsDefined(perkPrereq) ? perkPrereq.Level() : 0;
    }

    public static func GetRequiredPerkMaxLevel(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> Int32 {
        let perkRecord = CyberwareHelper.GetRequiredPerkRecord(equipArea, slotIndex);
        return IsDefined(perkRecord) ? perkRecord.GetLevelsCount() : 0;
    }

    public static func IsPerkRequired(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> Bool {
        let perkPrereq = CyberwareHelper.GetPerkPrereqRecord(equipArea, slotIndex);
        return IsDefined(perkPrereq);
    }

    public static func IsUnlockRequired(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> Bool {
        let anyPrereq = CyberwareHelper.GetPrereqRecord(equipArea, slotIndex);
        return IsDefined(anyPrereq);
    }

    public static func IsCyberdeckEquipped(owner: ref<GameObject>) -> Bool {
        return GameInstance.GetStatsSystem(owner.GetGame()).GetStatBoolValue(Cast(owner.GetEntityID()), gamedataStatType.HasCyberdeck);
    }

    public static func IsCyberwareArea(equipArea: gamedataEquipmentArea) -> Bool {
        switch equipArea {
            case gamedataEquipmentArea.ArmsCW:
            case gamedataEquipmentArea.CardiovascularSystemCW:
            case gamedataEquipmentArea.EyesCW:
            case gamedataEquipmentArea.FrontalCortexCW:
            case gamedataEquipmentArea.HandsCW:
            case gamedataEquipmentArea.IntegumentarySystemCW:
            case gamedataEquipmentArea.LegsCW:
            case gamedataEquipmentArea.MusculoskeletalSystemCW:
            case gamedataEquipmentArea.NervousSystemCW:
            case gamedataEquipmentArea.SystemReplacementCW:
                return true;
        }
        return false;
    }

    public static func CreateEquipSlotRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> TweakDBID {
        let equipAreaName = ToString(equipArea);
        let equipSlotName = s"EquipmentArea.\(equipAreaName)_Slot_\(slotIndex)";
        let equipSlotID = TDBID.Create(equipSlotName);

        if !IsDefined(TweakDBInterface.GetEquipSlotRecord(equipSlotID)) {
            TweakDBManager.CreateRecord(equipSlotID, n"EquipSlot");

            if Equals(equipArea, gamedataEquipmentArea.MusculoskeletalSystemCW) {
                let powerUpID = CyberwareHelper.CreatePowerUpRecord(equipArea, slotIndex);
                TweakDBManager.SetFlat(equipSlotID + t".OnInsertion", [powerUpID]);
            }

            TweakDBManager.UpdateRecord(equipSlotID);
            TweakDBManager.RegisterName(StringToName(equipSlotName));
        }

        return equipSlotID;
    }

    public static func CreateEquipSlotRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32, requiredPerk: gamedataNewPerkType, requiredLevel: Int32) -> TweakDBID {
        let equipAreaName = ToString(equipArea);
        let equipSlotName = s"EquipmentArea.\(equipAreaName)_Slot_\(slotIndex)_Perk_\(requiredPerk)_\(requiredLevel)";
        let equipSlotID = TDBID.Create(equipSlotName);

        if !IsDefined(TweakDBInterface.GetEquipSlotRecord(equipSlotID)) {
            let prereqName = s"Prereqs.HasPerk_\(requiredPerk)_\(requiredLevel)";
            let prereqID = TDBID.Create(prereqName);

            if !IsDefined(TweakDBInterface.GetPrereqRecord(prereqID)) {
                TweakDBManager.CreateRecord(prereqID, n"PlayerIsNewPerkBoughtPrereq");
                TweakDBManager.SetFlat(prereqID + t".perkType", ToString(requiredPerk));
                TweakDBManager.SetFlat(prereqID + t".level", requiredLevel);
                TweakDBManager.UpdateRecord(prereqID);
                TweakDBManager.RegisterName(StringToName(prereqName));
            }

            TweakDBManager.CreateRecord(equipSlotID, n"EquipSlot");
            TweakDBManager.SetFlat(equipSlotID + t".unlockPrereqRecord", prereqID);
            TweakDBManager.SetFlat(equipSlotID + t".visibleWhenLocked", true);

            if Equals(equipArea, gamedataEquipmentArea.MusculoskeletalSystemCW) {
                let powerUpID = CyberwareHelper.CreatePowerUpRecord(equipArea, slotIndex);
                TweakDBManager.SetFlat(equipSlotID + t".OnInsertion", [powerUpID]);
            }

            TweakDBManager.UpdateRecord(equipSlotID);
            TweakDBManager.RegisterName(StringToName(equipSlotName));
        }

        return equipSlotID;
    }

    public static func CreatePowerUpRecord(equipArea: gamedataEquipmentArea, slotIndex: Int32) -> TweakDBID {
        let equipAreaName = ToString(equipArea);
        let packageName = s"EquipmentArea.\(equipAreaName)_Slot_\(slotIndex)_PowerUp";
        let packageID = TDBID.Create(packageName);

        if !IsDefined(TweakDBInterface.GetGameplayLogicPackageRecord(packageID)) {
            let effectorName = s"\(packageName)_Effector";
            let effectorID = TDBID.Create(effectorName);

            if !IsDefined(TweakDBInterface.GetEffectorRecord(effectorID)) {
                TweakDBManager.CloneRecord(effectorID, t"Effectors.PowerUpCyberwareEffector");
                TweakDBManager.SetFlat(effectorID + t".targetEquipArea", equipAreaName);
                TweakDBManager.SetFlat(effectorID + t".targetEquipSlotIndex", slotIndex);
                TweakDBManager.UpdateRecord(effectorID);
                TweakDBManager.RegisterName(StringToName(effectorName));
            }

            TweakDBManager.CreateRecord(packageID, n"GameplayLogicPackage");
            TweakDBManager.SetFlat(packageID + t".effectors", [effectorID]);
            TweakDBManager.UpdateRecord(packageID);
            TweakDBManager.RegisterName(StringToName(packageName));
        }

        return packageID;
    }
}
