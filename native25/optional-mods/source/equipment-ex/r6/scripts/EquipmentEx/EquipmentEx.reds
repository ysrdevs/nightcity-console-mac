// EquipmentEx 1.2.9
module EquipmentEx
import Codeware.UI.*

public abstract class CompatibilityManager {
    public static func RequiredCodeware() -> String = "1.18.0";
    public static func RequiredArchiveXL() -> String = "1.26.0";
    public static func RequiredTweakXL() -> String = "1.11.3";

    public static func CheckRequirements() -> Bool {
        return Codeware.Require(CompatibilityManager.RequiredCodeware())
            && ArchiveXL.Require(CompatibilityManager.RequiredArchiveXL())
            && TweakXL.Require(CompatibilityManager.RequiredTweakXL());
    }

    public static func CheckConflicts(game: GameInstance, out conflicts: array<String>) -> Bool {
        if IsDefined(GameInstance.GetScriptableSystemsContainer(game).Get(n"WardrobeSystemExtra")) {
            ArrayPush(conflicts, "Wardrobe Extras");
        }

        let dataManager = new InventoryDataManagerV2();
        dataManager.Initialize(GetPlayer(game));
        let questsSystem = GameInstance.GetQuestsSystem(game);
        let transmogEnabled = questsSystem.GetFact(n"transmog_enabled");
        questsSystem.SetFact(n"transmog_enabled", 7);
        if dataManager.IsTransmogEnabled() != 7 {
            ArrayPush(conflicts, "True Hidden Everything");
        }
        questsSystem.SetFact(n"transmog_enabled", transmogEnabled);

        let itemController = new InventoryItemDisplayController();
        itemController.SetLocked(true, true);
        if !itemController.m_isLocked {
            if itemController.m_visibleWhenLocked {
                ArrayPush(conflicts, "No Special Outfit Lock");
            } else {
                ArrayPush(conflicts, "Never Lock Outfits");
            }
        }

        if GameFileExists("archive/pc/mod/basegame_underwear_patch.archive") {
            ArrayPush(conflicts, "Underwear Remover by Sorrow446");
        }

        return ArraySize(conflicts) == 0;
    }

    public static func CheckConflicts(game: GameInstance) -> Bool {
        let conflicts: array<String>;
        return CompatibilityManager.CheckConflicts(game, conflicts);
    }

    public static func IsUserNotified() -> Bool {
        return TweakDBInterface.GetBool(t"EquipmentEx.isUserNotified", false);
    }

    public static func MarkAsNotified() {
        TweakDBManager.SetFlat(t"EquipmentEx.isUserNotified", true);
    }
}

@if(ModuleExists("EquipmentEx.DevMode"))
public func DevMode() -> Bool = true;

@if(!ModuleExists("EquipmentEx.DevMode"))
public func DevMode() -> Bool = false;

public class InventoryHelper extends ScriptableSystem {
    private let m_player: wref<GameObject>;
    private let m_transactionSystem: wref<TransactionSystem>;
    private let m_wardrobeSystem: wref<WardrobeSystem>;
    private let m_inventoryManager: wref<InventoryDataManagerV2>;
    private let m_stash: wref<Stash>;

    private func OnPlayerAttach(request: ref<PlayerAttachRequest>) {
        this.m_player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
        this.m_transactionSystem = GameInstance.GetTransactionSystem(this.GetGameInstance());
        this.m_wardrobeSystem = GameInstance.GetWardrobeSystem(this.GetGameInstance());
        this.m_inventoryManager = EquipmentSystem.GetData(this.m_player).GetInventoryManager();
    }

    private func IsValidItem(itemID: ItemID) -> Bool {
        let itemRecordId = ItemID.GetTDBID(itemID);
        let itemRecord = TweakDBInterface.GetClothingRecord(itemRecordId);

        return IsDefined(itemRecord);
    }

    public func GetStash() -> wref<Stash> {
        return this.m_stash;
    }

    public func AddStash(stash: ref<Stash>) {
        if !IsDefined(this.m_stash) {
            this.m_stash = stash;
        }
    }

    public func GetStashItems(out items: array<InventoryItemData>) {
        let stashItems: array<wref<gameItemData>>;
        this.m_transactionSystem.GetItemList(this.m_stash, stashItems);

        for itemData in stashItems {
            if this.IsValidItem(itemData.GetID()) {
                ArrayPush(items, this.m_inventoryManager.GetCachedInventoryItemData(itemData));
            }
        }
    }

    public func GetPlayerItems(out items: array<InventoryItemData>, opt excludes: array<ItemModParams>) {
        for itemData in this.m_inventoryManager.GetPlayerInventoryData() {
            let itemID = itemData.ID;

            if this.IsValidItem(itemID) {
                let diff = 0;
                for exclude in excludes {
                    if Equals(exclude.itemID, itemID) {
                        diff += exclude.quantity;
                    }
                }

                if itemData.Quantity - diff > 0 {
                    ArrayPush(items, itemData);
                }
            }
        }
    }

    public func GetWardrobeItems(out items: array<InventoryItemData>) {
        for itemID in this.m_wardrobeSystem.GetStoredItemIDs() {
            if this.IsValidItem(itemID) {
                ArrayPush(items, this.m_inventoryManager.GetInventoryItemDataFromItemID(itemID));
            }
        }
    }

    public func GetAvailableItems(opt excludes: array<ItemModParams>) -> array<InventoryItemData> {
        let items: array<InventoryItemData>;

        switch ViewManager.GetInstance(this.GetGameInstance()).GetItemSource() {
            case WardrobeItemSource.InventoryOnly:
                this.GetPlayerItems(items, excludes);
                break;
            case WardrobeItemSource.InventoryAndStash:
                this.GetPlayerItems(items, excludes);
                this.GetStashItems(items);
                break;
            case WardrobeItemSource.WardrobeStore:
                this.GetWardrobeItems(items);
                break;
        }

        return items;
    }

    public func DiscardItem(itemID: ItemID) {
        switch ViewManager.GetInstance(this.GetGameInstance()).GetItemSource() {
            case WardrobeItemSource.InventoryOnly:
                this.m_transactionSystem.RemoveItem(this.m_player, itemID, 1);
                break;
            case WardrobeItemSource.InventoryAndStash:
                this.m_transactionSystem.RemoveItem(this.m_player, itemID, 1);
                this.m_transactionSystem.RemoveItem(this.m_stash, itemID, 1);
                break;
            case WardrobeItemSource.WardrobeStore:
                this.m_wardrobeSystem.ForgetItemID(itemID);
                break;
        }
    }

    public static func GetInstance(game: GameInstance) -> ref<InventoryHelper> {
        return GameInstance.GetScriptableSystemsContainer(game).Get(n"EquipmentEx.InventoryHelper") as InventoryHelper;
    }
}

struct ExtractedSet {
    public let setID: Int32;
    public let clothingList: array<SSlotVisualInfo>;
}

@if(!ModuleExists("ExtraWardrobeSlots.Utils"))
func ExtractClothingSets(game: GameInstance) -> array<ExtractedSet> {
    let wardrobeSystem = GameInstance.GetWardrobeSystem(game);
    let clothingSets = wardrobeSystem.GetClothingSets();
    let extractedSets: array<ExtractedSet>;

    for clothingSet in clothingSets {
        if ArraySize(clothingSet.clothingList) > 0 {
            ArrayPush(extractedSets, ExtractedSet(
                EnumInt(clothingSet.setID) + 1,
                clothingSet.clothingList
            ));
        }
    }

    return extractedSets;
}

@if(ModuleExists("ExtraWardrobeSlots.Utils"))
func ExtractClothingSets(game: GameInstance) -> array<ExtractedSet> {
    let wardrobeSystem = WardrobeSystemExtra.GetInstance(game);
    let clothingSets = wardrobeSystem.GetClothingSets();
    let extractedSets: array<ExtractedSet>;

    for clothingSet in clothingSets {
        if ArraySize(clothingSet.clothingList) > 0 {
            ArrayPush(extractedSets, new ExtractedSet(
                EnumInt(clothingSet.setID) + 1,
                clothingSet.clothingList
            ));
        }
    }

    return extractedSets;
}

struct BaseSlotConfig {
    public let slotID: TweakDBID;
    public let equipmentArea: gamedataEquipmentArea;

    public static func Create(slotID: TweakDBID, equipmentArea: gamedataEquipmentArea) -> BaseSlotConfig {
        return BaseSlotConfig(slotID, equipmentArea);
    }
}

struct ExtraSlotConfig {
    public let slotID: TweakDBID;
    public let slotName: CName;
    public let slotArea: CName;
    public let garmentOffset: Int32;
    public let relatedSlotIDs: array<TweakDBID>;
    public let dependencySlotIDs: array<TweakDBID>;
    public let displayName: String;

    public static func Create(slotArea: CName, slotName: CName, garmentOffset: Int32, opt relatedIDs: array<TweakDBID>, opt dependencyIDs: array<TweakDBID>) -> ExtraSlotConfig {
        return ExtraSlotConfig(
            TDBID.Create(NameToString(slotName)),
            slotName,
            slotArea,
            garmentOffset,
            relatedIDs,
            dependencyIDs,
            "Gameplay-" + StrReplace(NameToString(slotName), ".", "-")
        );
    }
}

public abstract class OutfitConfig {
    public static func BaseSlots() -> array<BaseSlotConfig> = [
        BaseSlotConfig.Create(t"AttachmentSlots.Head", gamedataEquipmentArea.Head),
        BaseSlotConfig.Create(t"AttachmentSlots.Eyes", gamedataEquipmentArea.Face),
        BaseSlotConfig.Create(t"AttachmentSlots.Chest", gamedataEquipmentArea.InnerChest),
        BaseSlotConfig.Create(t"AttachmentSlots.Torso", gamedataEquipmentArea.OuterChest),
        BaseSlotConfig.Create(t"AttachmentSlots.Legs", gamedataEquipmentArea.Legs),
        BaseSlotConfig.Create(t"AttachmentSlots.Feet", gamedataEquipmentArea.Feet),
        BaseSlotConfig.Create(t"AttachmentSlots.UnderwearTop", gamedataEquipmentArea.UnderwearTop),
        BaseSlotConfig.Create(t"AttachmentSlots.UnderwearBottom", gamedataEquipmentArea.UnderwearBottom)
    ];

    public static func OutfitSlots() -> array<ExtraSlotConfig> = [
        ExtraSlotConfig.Create(n"Head", n"OutfitSlots.Head", 310000, [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Head", n"OutfitSlots.Balaclava", 160000, [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.Mask", 170000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.Glasses", 190000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.Eyes", 130000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.EyeLeft", 140000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.EyeRight", 140000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Face", n"OutfitSlots.Wreath", 180000, [t"AttachmentSlots.Eyes"]),
        ExtraSlotConfig.Create(n"Ears", n"OutfitSlots.EarLeft", 140000, [], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Ears", n"OutfitSlots.EarRight", 140000, [], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Neck", n"OutfitSlots.Neckwear", 200000, [], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Neck", n"OutfitSlots.NecklaceTight", 190000, [], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Neck", n"OutfitSlots.NecklaceShort", 190000),
        ExtraSlotConfig.Create(n"Neck", n"OutfitSlots.NecklaceLong", 190000),
        ExtraSlotConfig.Create(n"Torso", n"OutfitSlots.TorsoUnder", 120000, [t"AttachmentSlots.Chest"], [t"AttachmentSlots.Head", t"AttachmentSlots.Torso"]),
        ExtraSlotConfig.Create(n"Torso", n"OutfitSlots.TorsoInner", 150000, [t"AttachmentSlots.Chest"], [t"AttachmentSlots.Head", t"AttachmentSlots.Torso"]),
        ExtraSlotConfig.Create(n"Torso", n"OutfitSlots.TorsoMiddle", 180000, [t"AttachmentSlots.Torso"], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Torso", n"OutfitSlots.TorsoOuter", 210000, [t"AttachmentSlots.Torso"], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Torso", n"OutfitSlots.TorsoAux", 240000, [t"AttachmentSlots.Torso"], [t"AttachmentSlots.Head"]),
        ExtraSlotConfig.Create(n"Back", n"OutfitSlots.Back", 220000),
        ExtraSlotConfig.Create(n"Waist", n"OutfitSlots.Waist", 200000),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.ShoulderLeft", 200000),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.ShoulderRight", 200000),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.ElbowLeft", 200000),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.ElbowRight", 200000),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.WristLeft", 160000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Arms", n"OutfitSlots.WristRight", 160000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Hands", n"OutfitSlots.Hands", 160000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Hands", n"OutfitSlots.HandLeft", 170000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Hands", n"OutfitSlots.HandRight", 170000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Hands", n"OutfitSlots.HandPropLeft", 310000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Hands", n"OutfitSlots.HandPropRight", 310000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Fingers", n"OutfitSlots.FingersLeft", 180000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Fingers", n"OutfitSlots.FingersRight", 180000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Fingers", n"OutfitSlots.FingernailsLeft", 100000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Fingers", n"OutfitSlots.FingernailsRight", 100000, [], [t"AttachmentSlots.Hands"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.LegsInner", 130000, [t"AttachmentSlots.Legs"], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.LegsMiddle", 160000, [t"AttachmentSlots.Legs"], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.LegsOuter", 190000, [t"AttachmentSlots.Legs"], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.ThighLeft", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.ThighRight", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.KneeLeft", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.KneeRight", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.AnkleLeft", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Legs", n"OutfitSlots.AnkleRight", 140000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Feet", n"OutfitSlots.Feet", 180000, [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Toes", n"OutfitSlots.ToesLeft", 120000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Toes", n"OutfitSlots.ToesRight", 120000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Toes", n"OutfitSlots.ToenailsLeft", 100000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Toes", n"OutfitSlots.ToenailsRight", 100000, [], [t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Body", n"OutfitSlots.BodyUnder", 110000, [t"AttachmentSlots.Chest", t"AttachmentSlots.Legs"], [t"AttachmentSlots.Head", t"AttachmentSlots.Torso", t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Body", n"OutfitSlots.BodyInner", 140000, [t"AttachmentSlots.Chest", t"AttachmentSlots.Legs"], [t"AttachmentSlots.Head", t"AttachmentSlots.Torso", t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Body", n"OutfitSlots.BodyMiddle", 170000, [t"AttachmentSlots.Torso", t"AttachmentSlots.Legs"], [t"AttachmentSlots.Head", t"AttachmentSlots.Feet"]),
        ExtraSlotConfig.Create(n"Body", n"OutfitSlots.BodyOuter", 300000, [t"AttachmentSlots.Torso", t"AttachmentSlots.Legs"], [t"AttachmentSlots.Head", t"AttachmentSlots.Feet"])
   ];
}

public class OutfitUpdated extends Event {
    public let isActive: Bool;
    public let outfitName: CName;
}

public class OutfitPartUpdated extends Event {
    public let itemID: ItemID;
    public let itemName: String;
    public let slotID: TweakDBID;
    public let slotName: String;
    public let isEquipped: Bool;
}

public class OutfitMappingUpdated extends Event {}

public class OutfitListUpdated extends Event {}

public class OutfitPart {
    private persistent let m_itemID: ItemID;
    private persistent let m_slotID: TweakDBID;

    public func GetItemID() -> ItemID {
        return this.m_itemID;
    }

    public func GetItemHash() -> Uint64 {
        return ItemID.GetCombinedHash(this.m_itemID);
    }

    public func SetItemID(itemID: ItemID) {
        this.m_itemID = itemID;
    }

    public func GetSlotID() -> TweakDBID {
        return this.m_slotID;
    }

    public func SetSlotID(slotID: TweakDBID) {
        this.m_slotID = slotID;
    }

    public static func Create(itemID: ItemID, slotID: TweakDBID) -> ref<OutfitPart> {
        let instance = new OutfitPart();
        instance.m_itemID = itemID;
        instance.m_slotID = slotID;
        return instance;
    }

    public static func Clone(source: ref<OutfitPart>) -> ref<OutfitPart> {
        return OutfitPart.Create(source.m_itemID, source.m_slotID);
    }
}

class OutfitSet {
    private persistent let m_name: CName;
    private persistent let m_parts: array<ref<OutfitPart>>;
    private persistent let m_timestamp: Float;
    private let m_hash: Uint64;

    public func GetName() -> CName {
        return this.m_name;
    }

    public func SetName(name: CName) {
        this.m_name = name;
    }

    public func GetParts() -> array<ref<OutfitPart>> {
        return this.m_parts;
    }

    public func SetParts(parts: array<ref<OutfitPart>>) {
        ArrayResize(this.m_parts, ArraySize(parts));

        let i = 0;
        for part in parts {
            this.m_parts[i] = OutfitPart.Clone(part);
            i += 1;
        }

        this.UpdateHash();
    }

    public func GetHash() -> Uint64 {
        return this.m_hash;
    }

    public func UpdateHash() {
        this.m_hash = OutfitSet.MakeHash(this.m_parts);
    }

    public static func Create(name: CName, timestamp: Float, parts: array<ref<OutfitPart>>) -> ref<OutfitSet> {
        let instance = new OutfitSet();
        instance.m_name = name;
        instance.m_timestamp = timestamp;
        instance.SetParts(parts);
        return instance;
    }

    public static func Clone(name: CName, timestamp: Float, source: ref<OutfitSet>) -> ref<OutfitSet> {
        return OutfitSet.Create(name, timestamp, source.m_parts);
    }
    
    public static func MakeHash(parts: array<ref<OutfitPart>>) -> Uint64 {
        if ArraySize(parts) == 0 {
            return 0ul;
        }

        let items: array<Uint64>;

        for part in parts {
            let item = part.GetItemHash();

            let index = 0;
            while index < ArraySize(items) && items[index] < item {
                index += 1;
            }

            ArrayInsert(items, index, item);
        }

        let hash = 14695981039346656037ul; // 0xcbf29ce484222325
        let prime = 1099511628211ul; // 0x00000100000001B3
        let base = 256ul;

        for item in items {
            let i = 8;
            while i > 0 {
                hash = hash ^ (item % base);
                hash *= prime;
                item /= base;
                i -= 1;
            }
        }

        return hash;
    }
}

class OutfitState {
    private persistent let m_disabled: Bool;
    private persistent let m_active: Bool;
    private persistent let m_parts: array<ref<OutfitPart>>;
    private persistent let m_outfits: array<ref<OutfitSet>>;
    private persistent let m_mappings: array<ref<OutfitPart>>;
    private let m_hash: Uint64;

    public func IsDisabled() -> Bool {
        return this.m_disabled;
    }

    public func SetDisabled(state: Bool) {
        this.m_disabled = state;
    }

    public func IsActive() -> Bool {
        return this.m_active;
    }

    public func SetActive(state: Bool) {
        this.m_active = state;
    }

    public func GetParts() -> array<ref<OutfitPart>> {
        return this.m_parts;
    }

    public func HasPart(itemID: ItemID) -> Bool {
        return IsDefined(this.GetPart(itemID));
    }

    public func HasPart(slotID: TweakDBID) -> Bool {
        return IsDefined(this.GetPart(slotID));
    }

    public func GetPart(itemID: ItemID) -> ref<OutfitPart> {
        for part in this.m_parts {
            if Equals(part.GetItemID(), itemID) {
                return part;
            }
        }
        return null;
    }

    public func GetPart(slotID: TweakDBID) -> ref<OutfitPart> {
        for part in this.m_parts {
            if Equals(part.GetSlotID(), slotID) {
                return part;
            }
        }
        return null;
    }

    public func UpdatePart(itemID: ItemID, slotID: TweakDBID) {
        let updated = false;

        for part in this.m_parts {
            if Equals(part.GetItemID(), itemID) {
                if Equals(part.GetSlotID(), slotID) {
                    return;
                }
                part.SetSlotID(slotID);
                updated = true;
                break;
            }
        }

        for part in this.m_parts {
            if Equals(part.GetSlotID(), slotID) {
                if updated {
                    if NotEquals(part.GetItemID(), itemID) {
                        ArrayRemove(this.m_parts, part);
                    }
                } else {
                    part.SetItemID(itemID);
                    updated = true;
                }
                break;
            }
        }

        if !updated {
            ArrayPush(this.m_parts, OutfitPart.Create(itemID, slotID));
        }

        this.UpdateHash();
    }

    public func RemovePart(itemID: ItemID) -> Bool {
        for part in this.m_parts {
            if Equals(part.GetItemID(), itemID) {
                ArrayRemove(this.m_parts, part);
                this.UpdateHash();
                return true;
            }
        }
        return false;
    }

    public func RemovePart(slotID: TweakDBID) -> Bool {
        for part in this.m_parts {
            if Equals(part.GetSlotID(), slotID) {
                ArrayRemove(this.m_parts, part);
                this.UpdateHash();
                return true;
            }
        }
        return false;
    }

    public func ClearParts() {
        ArrayClear(this.m_parts);

        this.UpdateHash();
    }

    public func GetOutfits() -> array<ref<OutfitSet>> {
        return this.m_outfits;
    }

    public func GetOutfit(name: CName) -> ref<OutfitSet> {
        for outfit in this.m_outfits {
            if Equals(outfit.GetName(), name) {
                return outfit;
            }
        }
        return null;
    }

    public func GetOutfitParts(name: CName) -> array<ref<OutfitPart>> {
		let outfit = this.GetOutfit(name);
		return IsDefined(outfit) ? outfit.GetParts() : [];
	}

    public func SaveOutfit(name: CName, overwrite: Bool, timestamp: Float) -> Bool {
        return this.SaveOutfit(name, this.m_parts, overwrite, timestamp);
    }

    public func SaveOutfit(name: CName, parts: array<ref<OutfitPart>>, overwrite: Bool, timestamp: Float) -> Bool {
        let outfit = this.GetOutfit(name);

        if IsDefined(outfit) {
            if !overwrite {
                return false;
            }

            outfit.SetParts(parts);
            return true;            
        }
        
        ArrayPush(this.m_outfits, OutfitSet.Create(name, timestamp, parts));
        return true;
    }

    public func CopyOutfit(name: CName, from: CName, timestamp: Float) -> Bool {
        let outfit = this.GetOutfit(name);

        if !IsDefined(outfit) {
            return false;
        }

        ArrayPush(this.m_outfits, OutfitSet.Clone(name, timestamp, outfit));
        return true;
    }

    public func DeleteOutfit(name: CName) -> Bool {
        let outfit = this.GetOutfit(name);

        if !IsDefined(outfit) {
            return false;
        }

        ArrayRemove(this.m_outfits, outfit);
        return true;
    }

    public func DeleteAllOutfits() -> Bool {
        if ArraySize(this.m_outfits) > 0 {
            ArrayClear(this.m_outfits);
            return true;
        }

        return false;
    }

    public func IsOutfit(name: CName) -> Bool {
        let outfit = this.GetOutfit(name);

        return IsDefined(outfit) ? this.m_hash == outfit.GetHash() : false;
    }

    public func IsOutfit(hash: Uint64) -> Bool {
        return this.m_hash == hash;
    }

    public func GetMappings() -> array<ref<OutfitPart>> {
        return this.m_mappings;
    }

    public func UpdateMapping(itemID: ItemID, slotID: TweakDBID) {
        let updated = false;

        for mapping in this.m_mappings {
            if Equals(mapping.GetItemID(), itemID) {
                if Equals(mapping.GetSlotID(), slotID) {
                    return;
                }
                mapping.SetSlotID(slotID);
                updated = true;
                break;
            }
        }

        if !updated {
            ArrayPush(this.m_mappings, OutfitPart.Create(itemID, slotID));
        }
    }

    public func UpdateHash() {
        this.m_hash = OutfitSet.MakeHash(this.m_parts);
    }

    public func Restore() {
        this.UpdateHash();

        for outfit in this.m_outfits {
            outfit.UpdateHash();
        }
    }

    public static func Create() -> ref<OutfitState> {
        return new OutfitState();
    }
}

public class OutfitSystem extends ScriptableSystem {
    private persistent let m_state: ref<OutfitState>;
    private let m_firstUse: Bool;

    private let m_baseSlots: array<TweakDBID>;
    private let m_outfitSlots: array<TweakDBID>;
    private let m_managedSlots: array<TweakDBID>;
    private let m_managedAreas: array<gamedataEquipmentArea>;

    private let m_player: wref<GameObject>;
    private let m_equipmentData: wref<EquipmentSystemPlayerData>;
    private let m_transactionSystem: wref<TransactionSystem>;
    private let m_attachmentSlotsListener: ref<AttachmentSlotsScriptListener>;
    private let m_delaySystem: wref<DelaySystem>;

    private let m_equipmentDef: wref<UI_EquipmentDef>;
    private let m_equipmentBlackboard: wref<IBlackboard>;
    private let m_equipmentHash: Uint64;

    private func OnAttach() {
        this.InitializeState();
        this.InitializeSlotsInfo();
        this.InitializeBlackboards();
        this.ApplyMappings();
    }

    private func OnDetach() {
        this.ResetMappings();
        this.UninitializeSystems();
    }

    private func OnRestored(saveVersion: Int32, gameVersion: Int32) {
        this.InitializePlayerAndSystems();
        this.CleanUpPreviewItems();
        this.MigrateState();

        if this.m_state.IsActive() {
            this.HideEquipment();
            this.EnableGarmentOffsets();

            this.m_delaySystem.DelayCallback(DelayedRestoreCallback.Create(this), 1.0 / 30.0, false);
        }
    }

    private func OnPlayerAttach(request: ref<PlayerAttachRequest>) {
        this.InitializePlayerAndSystems();
        this.ConvertClothingSets();
    }

    private func InitializeState() {
        if !IsDefined(this.m_state) {
            this.m_state = new OutfitState();
            this.m_firstUse = true;
        } else {
            this.m_state.Restore();
        }
    }

    private func InitializeSlotsInfo() {
        for baseSlot in OutfitConfig.BaseSlots() {
            ArrayPush(this.m_baseSlots, baseSlot.slotID);
            ArrayPush(this.m_managedSlots, baseSlot.slotID);
            ArrayPush(this.m_managedAreas, baseSlot.equipmentArea);
        }

        for outfitSlot in OutfitConfig.OutfitSlots() {
            ArrayPush(this.m_outfitSlots, outfitSlot.slotID);
            ArrayPush(this.m_managedSlots, outfitSlot.slotID);

        }
    }

    private func InitializeBlackboards() {
        this.m_equipmentDef = GetAllBlackboardDefs().UI_Equipment;
        this.m_equipmentBlackboard = GameInstance.GetBlackboardSystem(this.GetGameInstance()).Get(this.m_equipmentDef);
    }

    private func InitializePlayerAndSystems() {
        if !IsDefined(this.m_player) {
            this.m_player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
            this.m_equipmentData = EquipmentSystem.GetData(this.m_player);
            this.m_transactionSystem = GameInstance.GetTransactionSystem(this.GetGameInstance());
            this.m_attachmentSlotsListener = this.m_transactionSystem.RegisterAttachmentSlotListener(this.m_player, PlayerSlotsCallback.Create(this));
            this.m_delaySystem = GameInstance.GetDelaySystem(this.GetGameInstance());
        }
    }

    private func UninitializeSystems() {
        if IsDefined(this.m_attachmentSlotsListener) {
            this.m_transactionSystem.UnregisterAttachmentSlotListener(this.m_player, this.m_attachmentSlotsListener);
        }
    }

    private func ConvertClothingSets() {
        if this.m_firstUse {
            let clothingSets = ExtractClothingSets(this.GetGameInstance());

            for clothingSet in clothingSets {
                let outfitParts: array<ref<OutfitPart>>;

                for clothingItem in clothingSet.clothingList {
                    if ItemID.IsValid(clothingItem.visualItem) && !clothingItem.isHidden {
                        let itemID = clothingItem.visualItem;
                        let slotID = this.GetItemSlot(itemID);

                        if this.IsOutfitSlot(slotID) {
                            ArrayPush(outfitParts, OutfitPart.Create(itemID, slotID));
                        }
                    }
                }

                if ArraySize(outfitParts) > 0 {
                    let outfitName = StringToName("WARDROBE SET " + ToString(clothingSet.setID));
                    this.m_state.SaveOutfit(outfitName, outfitParts, false, this.GetTimestamp());
                }
            }
        }
    }

    private func GetTimestamp() -> Float {
        return EngineTime.ToFloat(GameInstance.GetPlaythroughTime(this.GetGameInstance()));
    }

    private func AddItemToState(itemID: ItemID, slotID: TweakDBID) {
        this.m_state.UpdatePart(itemID, slotID);
    }

    private func RemoveItemFromState(itemID: ItemID) {
        this.m_state.RemovePart(itemID);
    }

    private func RemoveSlotFromState(slotID: TweakDBID) {
        this.m_state.RemovePart(slotID);
    }

    private func RemoveAllItemsFromState() {
        this.m_state.ClearParts();
    }

    private func CleanUpPreviewItems() {
        let playerItems: array<wref<gameItemData>>;
        if this.m_transactionSystem.GetItemList(this.m_player, playerItems) {
            for itemData in playerItems {
                let itemID = itemData.GetID();
                if ItemID.HasFlag(itemID, gameEItemIDFlag.Preview) {
                    this.m_transactionSystem.RemoveItem(this.m_player, itemID, 1);
                }
            }
        }
    }

    private func MigrateState() {
        for part in this.m_state.GetParts() {
            let itemID = part.GetItemID();
            let slotID = this.GetItemSlot(itemID);

            if NotEquals(slotID, part.GetSlotID()) {
                if this.IsOutfitSlot(slotID) {
                    this.m_state.UpdatePart(itemID, slotID);
                } else {
                    this.m_state.RemovePart(itemID);
                }
            }
        }
    }

    private func AttachVisualToSlot(itemID: ItemID, slotID: TweakDBID) {
        let randomID = ItemID.FromTDBID(ItemID.GetTDBID(itemID));
        let previewID = this.m_transactionSystem.CreatePreviewItemID(randomID);

        this.m_transactionSystem.GivePreviewItemByItemID(this.m_player, randomID);
        this.m_transactionSystem.AddItemToSlot(this.m_player, slotID, previewID, true);
        this.m_equipmentData.SendEquipAudioEvents(previewID);

        this.TriggerAttachmentEvent(itemID, slotID);
        this.UpdateBlackboard(itemID, slotID);
    }

    private func DetachVisualFromSlot(itemID: ItemID, slotID: TweakDBID) {
        let itemObject = this.m_transactionSystem.GetItemInSlot(this.m_player, slotID);
        if IsDefined(itemObject) {
            let previewID = itemObject.GetItemID();

            this.m_transactionSystem.RemoveItemFromSlot(this.m_player, slotID);
            this.m_transactionSystem.RemoveItem(this.m_player, previewID, 1);
            this.m_equipmentData.SendUnequipAudioEvents(previewID);
        }

        this.TriggerDetachmentEvent(itemID, slotID);
        this.UpdateBlackboard(slotID);
    }

    private func AttachAllVisualsToSlots(opt refresh: Bool) {
        for part in this.m_state.GetParts() {
            if this.IsOutfitSlot(part.GetSlotID()) && this.IsEquippable(part.GetItemID()) {
                this.AttachVisualToSlot(part.GetItemID(), part.GetSlotID());

                if refresh {
                    this.RefreshSlotAttachment(part.GetSlotID());
                }
            }
        }
    }

    private func DetachAllVisualsFromSlots(opt refresh: Bool) {
        for part in this.m_state.GetParts() {
            if this.IsOutfitSlot(part.GetSlotID()) {
                this.DetachVisualFromSlot(part.GetItemID(), part.GetSlotID());

                if refresh {
                    this.RefreshSlotAttachment(part.GetSlotID());
                }
            }
        }
    }

    private func ReattachVisualInSlot(slotID: TweakDBID) {
        let part = this.m_state.GetPart(slotID);
        if IsDefined(part) {
            let itemObject = this.m_transactionSystem.GetItemInSlot(this.m_player, slotID);
            if IsDefined(itemObject) {
                let previewID = itemObject.GetItemID();
                this.m_transactionSystem.RemoveItemFromSlot(this.m_player, slotID);
                this.m_delaySystem.DelayCallback(DelayedAttachCallback.Create(this.m_transactionSystem, this.m_player, slotID, previewID), 1.0 / 30.0, false);
            }
        }
    }


    private func RefreshSlotAttachment(slotID: TweakDBID) {
        this.m_transactionSystem.RefreshAttachment(this.m_player, slotID);
    }


    private func EnableGarmentOffsets() {
        ArchiveXL.EnableGarmentOffsets();
    }

    private func DisableGarmentOffsets() {
        ArchiveXL.DisableGarmentOffsets();
    }

    private func HideEquipment() {
        this.m_equipmentData.UnlockVisualChanges();
        this.m_equipmentData.UnequipItem(this.m_equipmentData.GetEquipAreaIndex(gamedataEquipmentArea.Outfit), 0, false);

        for baseSlot in OutfitConfig.BaseSlots() {
            this.m_equipmentData.ClearVisuals(baseSlot.equipmentArea);
        }

        this.m_equipmentData.LockVisualChanges();
        this.UpdateEquipmentHash();
    }

    private func ShowEquipment() {
        this.m_equipmentData.UnlockVisualChanges();

        for baseSlot in OutfitConfig.BaseSlots() {
            this.m_equipmentData.UnequipVisuals(baseSlot.equipmentArea);
        }

        this.m_equipmentData.LockVisualChanges();
        this.ResetEquipmentHash();
    }

    private func CloneEquipment(opt ignoreItemID: ItemID, opt ignoreSlotID: TweakDBID) {
        for baseSlotID in this.m_baseSlots {
            let itemObject = this.m_transactionSystem.GetItemInSlot(this.m_player, baseSlotID);
            if IsDefined(itemObject) {
                let itemID = itemObject.GetItemID();
                if NotEquals(itemID, ignoreItemID){
                    let slotID = this.GetItemSlot(itemID);
                    if this.IsOutfitSlot(slotID) && NotEquals(slotID, ignoreSlotID) {
                        this.EquipItem(itemID, slotID);
                        this.RefreshSlotAttachment(slotID);
                    }
                }
            }
        }

        this.UpdateEquipmentHash();
    }

    private func GetEquipmentParts() -> array<ref<OutfitPart>> {
        let parts: array<ref<OutfitPart>>;

        for baseSlot in OutfitConfig.BaseSlots() {
            let itemID = this.m_equipmentData.GetActiveItem(baseSlot.equipmentArea);
            if ItemID.IsValid(itemID) {
                let visualTag = this.m_equipmentData.GetVisualTagByAreaType(baseSlot.equipmentArea);
                let forceHide = this.m_equipmentData.IsVisualTagActive(visualTag);
                if !forceHide {
                    ArrayPush(parts, OutfitPart.Create(itemID, baseSlot.slotID));
                }
            }
        }

        return parts;
    }

    private func ResetEquipmentHash() {
        this.m_equipmentHash = 0ul;
    }

    private func UpdateEquipmentHash() {
        this.m_equipmentHash = OutfitSet.MakeHash(this.GetEquipmentParts());
    }

    private func UpdateBlackboard(slotID: TweakDBID) {
        this.UpdateBlackboard(ItemID.None(), slotID);
    }

    private func UpdateBlackboard(itemID: ItemID, slotID: TweakDBID) {
        this.m_equipmentBlackboard.SetInt(this.m_equipmentDef.areaChangedSlotIndex, 0);
        this.m_equipmentBlackboard.SetInt(this.m_equipmentDef.areaChanged, EnumInt(gamedataEquipmentArea.Invalid), true);

        this.m_equipmentBlackboard.SetVariant(this.m_equipmentDef.itemEquipped, ToVariant(itemID), true);

        let modifiedArea: SPaperdollEquipData;
        modifiedArea.equipped = ItemID.IsValid(itemID);
        modifiedArea.placementSlot = slotID;
        this.m_equipmentBlackboard.SetVariant(this.m_equipmentDef.lastModifiedArea, ToVariant(modifiedArea), true);

        this.m_equipmentBlackboard.FireCallbacks();
    }
    
    private func TriggerActivationEvent(opt outfitName: CName) {
        let event = new OutfitUpdated();
        event.isActive = true;
        event.outfitName = outfitName;

        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(event);
    }

    private func TriggerDeactivationEvent() {
        let event = new OutfitUpdated();
        event.isActive = false;

        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(event);
    }

    private func TriggerAttachmentEvent(itemID: ItemID, slotID: TweakDBID) {
        let event = new OutfitPartUpdated();
        event.itemID = itemID;
        event.itemName = this.GetItemName(itemID);
        event.slotID = slotID;
        event.slotName = this.GetSlotName(slotID);
        event.isEquipped = true;

        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(event);
    }

    private func TriggerDetachmentEvent(itemID: ItemID, slotID: TweakDBID) {
        let event = new OutfitPartUpdated();
        event.itemID = itemID;
        event.itemName = this.GetItemName(itemID);
        event.slotID = slotID;
        event.slotName = this.GetSlotName(slotID);
        event.isEquipped = false;

        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(event);       
    }

    private func TriggerOutfitListEvent() {
        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(new OutfitListUpdated());
    }

    private func TriggerMappingEvent() {
        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(new OutfitMappingUpdated());
    }

    public func IsBlocked() -> Bool {
        if this.m_state.IsDisabled() {
            return true;
        }

        let outfitItem = this.m_transactionSystem.GetItemInSlot(this.m_player, t"AttachmentSlots.Outfit");
        if IsDefined(outfitItem) && outfitItem.GetItemData().HasTag(n"UnequipBlocked") {
            return true;
        }

        return false;
    }

    public func IsDisabled() -> Bool {
        return this.m_state.IsDisabled();
    }

    public func Enable() {
        this.m_state.SetDisabled(false);
    }

    public func Disable() {
        this.m_state.SetDisabled(true);
    }

    public func IsActive() -> Bool {
        return this.m_state.IsActive();
    }

    public func Activate() {
        if this.IsBlocked() {
            return;
        }

        if !this.m_state.IsActive() {
            this.HideEquipment();

            this.m_state.SetActive(true);
            this.m_state.ClearParts();

            this.EnableGarmentOffsets();
            this.CloneEquipment();
            
            this.TriggerActivationEvent();
        }
    }

    private func ActivateWithoutClone() {
        if this.IsBlocked() {
            return;
        }

        if !this.m_state.IsActive() {
            this.HideEquipment();

            this.m_state.SetActive(true);
            this.m_state.ClearParts();

            this.EnableGarmentOffsets();

            this.TriggerActivationEvent();
        }
    }

    private func ActivateWithoutSlot(slotID: TweakDBID) {
        if this.IsBlocked() {
            return;
        }

        if !this.m_state.IsActive() {
            this.HideEquipment();

            this.m_state.SetActive(true);
            this.m_state.ClearParts();

            this.EnableGarmentOffsets();
            this.CloneEquipment(ItemID.None(), slotID);

            this.TriggerActivationEvent();
        }
    }

    private func ActivateWithoutItem(itemID: ItemID) {
        if this.IsBlocked() {
            return;
        }

        if !this.m_state.IsActive() {
            this.HideEquipment();

            this.m_state.SetActive(true);
            this.m_state.ClearParts();

            this.EnableGarmentOffsets();
            this.CloneEquipment(itemID, TDBID.None());

            this.TriggerActivationEvent();
        }
    }

    public func Reactivate() {
        if this.IsBlocked() {
            return;
        }

        if !this.m_state.IsActive() {
            this.HideEquipment();

            this.m_state.SetActive(true);
            
            this.EnableGarmentOffsets();
            this.AttachAllVisualsToSlots(true);

            this.TriggerActivationEvent();
        }
    }

    public func Deactivate() {
        if this.m_state.IsActive() {
            this.m_state.SetActive(false);

            this.DisableGarmentOffsets();
            this.ShowEquipment();
            this.DetachAllVisualsFromSlots(false);

            this.TriggerDeactivationEvent();
        }
    }

    public func GetItemSlot(recordID: TweakDBID) -> TweakDBID {
        let supportedSlots = TweakDBInterface.GetForeignKeyArray(recordID + t".placementSlots");
        return ArraySize(supportedSlots) > 0 ? ArrayLast(supportedSlots) : TDBID.None();
    }

    public func GetItemSlot(itemID: ItemID) -> TweakDBID {
        return ItemID.IsValid(itemID) ? this.GetItemSlot(ItemID.GetTDBID(itemID)) : TDBID.None();
    }



    public func IsOccupied(slotID: TweakDBID) -> Bool {
        return this.m_state.IsActive() && this.m_state.HasPart(slotID);
    }

    public func IsEquipped(itemID: ItemID) -> Bool {
        return this.m_state.IsActive() && this.m_state.HasPart(itemID);
    }

    public func IsEquippable(recordID: TweakDBID) -> Bool {
        let itemRecord = TweakDBInterface.GetItemRecord(recordID);

        if !IsDefined(itemRecord) {
            return false;
        }

        if !Equals(itemRecord.ItemCategory().Type(), gamedataItemCategory.Clothing) {
            return false;
        }

        if !this.IsOutfitSlot(this.GetItemSlot(recordID)) {
            return false;
        }

        return true;
    }

    public func IsEquippable(itemID: ItemID) -> Bool {
        if !ItemID.IsValid(itemID) {
            return false;
        }

        return this.IsEquippable(ItemID.GetTDBID(itemID));
    }

    public func IsEquippable(recordID: TweakDBID, slotID: TweakDBID) -> Bool {
        return this.IsEquippable(recordID) && this.GetItemSlot(recordID) == slotID;
    }

    public func IsEquippable(itemID: ItemID, slotID: TweakDBID) -> Bool {
        return this.IsEquippable(itemID) && this.GetItemSlot(itemID) == slotID;
    }

    public func EquipItem(recordID: TweakDBID, opt slotID: TweakDBID) -> Bool {
        if !this.IsEquippable(recordID) {
            return false;
        }
        
        let itemID = this.GiveItem(recordID);

        return this.EquipItem(itemID, slotID);
    }

    public func EquipItem(itemID: ItemID, opt slotID: TweakDBID) -> Bool {
        if this.IsBlocked() {
            return false;
        }

        if TDBID.IsValid(slotID) {
            if !this.IsEquippable(itemID, slotID) {
                return false;
            }
        } else {
            if !this.IsEquippable(itemID) {
                return false;
            }
            slotID = this.GetItemSlot(itemID);
        }
        
        this.ActivateWithoutSlot(slotID);

        this.UnequipItem(itemID);
        this.UnequipSlot(slotID);

        this.AddItemToState(itemID, slotID);
        this.AttachVisualToSlot(itemID, slotID);

        return true;
    }

    public func UnequipItem(recordID: TweakDBID) -> Bool {
        if this.IsBlocked() {
            return false;
        }

        let itemData = this.m_transactionSystem.GetItemDataByTDBID(this.m_player, recordID);

        if !IsDefined(itemData) {
            return false;
        }

        return this.UnequipItem(itemData.GetID());
    }

    public func UnequipItem(itemID: ItemID) -> Bool {
        if this.IsBlocked() {
            return false;
        }

        this.ActivateWithoutItem(itemID);
        
        let part = this.m_state.GetPart(itemID);

        if !IsDefined(part) {
            return false;
        }

        let slotID = part.GetSlotID();

        this.RemoveItemFromState(itemID);
        this.DetachVisualFromSlot(itemID, slotID);

        return true;
    }

    public func UnequipSlot(slotID: TweakDBID) -> Bool {
        if this.IsBlocked() {
            return false;
        }

        this.ActivateWithoutSlot(slotID);

        let part = this.m_state.GetPart(slotID);

        if !IsDefined(part) {
            return false;
        }

        let itemID = part.GetItemID();

        this.RemoveItemFromState(itemID);
        this.DetachVisualFromSlot(itemID, slotID);

        return true;
    }

    public func UnequipAll() {
        if this.IsBlocked() {
            return;
        }

        if this.m_state.IsActive() {
            for part in this.m_state.GetParts() {
                if this.IsOutfitSlot(part.GetSlotID()) {
                    this.RemoveItemFromState(part.GetItemID());
                    this.DetachVisualFromSlot(part.GetItemID(), part.GetSlotID());
                }
            }
        } else {
            this.ActivateWithoutClone();
        }
    }

    public func AssignItem(itemID: ItemID, slotID: TweakDBID) -> Bool {
        if !this.IsEquippable(itemID) || !this.IsOutfitSlot(slotID) {
            return false;
        }

        let oldSlotID = this.GetItemSlot(itemID);

        if Equals(slotID, oldSlotID) {
            return false;
        }
        
        this.m_state.UpdateMapping(itemID, slotID);

        this.ApplyMapping(itemID, slotID);
        this.TriggerMappingEvent();

        if this.IsEquipped(itemID) {
            this.DetachVisualFromSlot(itemID, oldSlotID);
            this.m_delaySystem.DelayCallback(DelayedEquipCallback.Create(this, itemID), 1.0 / 30.0, false);
        }

        return true;
    }

    private func ApplyMapping(itemID: ItemID, slotID: TweakDBID) {
        for outfitSlot in OutfitConfig.OutfitSlots() {
            if Equals(outfitSlot.slotID, slotID) {
                let record = TweakDBInterface.GetClothingRecord(ItemID.GetTDBID(itemID));

                let placementSlots = TweakDBInterface.GetForeignKeyArray(record.GetID() + t".placementSlots");
                ArrayResize(placementSlots, 2);
                if NotEquals(outfitSlot.slotID, ArrayLast(placementSlots)) {
                    ArrayPush(placementSlots, outfitSlot.slotID);
                }

                TweakDBManager.SetFlat(record.GetID() + t".placementSlots", placementSlots);
                TweakDBManager.SetFlat(record.GetID() + t".garmentOffset", outfitSlot.garmentOffset);
                TweakDBManager.UpdateRecord(record.GetID());
                break;
            }
        }
    }

    private func ResetMapping(itemID: ItemID) {
        let record = TweakDBInterface.GetClothingRecord(ItemID.GetTDBID(itemID));

        let placementSlots = TweakDBInterface.GetForeignKeyArray(record.GetID() + t".placementSlots");
        ArrayResize(placementSlots, 2); //ArrayPop(placementSlots);
        let previousSlotID = ArrayLast(placementSlots);

        for outfitSlot in OutfitConfig.OutfitSlots() {
            if Equals(outfitSlot.slotID, previousSlotID) {
                TweakDBManager.SetFlat(record.GetID() + t".placementSlots", placementSlots);
                TweakDBManager.SetFlat(record.GetID() + t".garmentOffset", outfitSlot.garmentOffset);
                TweakDBManager.UpdateRecord(record.GetID());
                break;
            }
        }
    }

    private func ApplyMappings() {
        for mapping in this.m_state.GetMappings() {
            this.ApplyMapping(mapping.GetItemID(), mapping.GetSlotID());
        }
    }

    private func ResetMappings() {
        for mapping in this.m_state.GetMappings() {
            this.ResetMapping(mapping.GetItemID());
        }
    }

    public func IsEquipped(name: CName) -> Bool {
        return this.m_state.IsActive()
            ? this.m_state.IsOutfit(name)
            : Equals(name, n"");
    }

    public func HasOutfit(name: CName) -> Bool {
        return IsDefined(this.m_state.GetOutfit(name));
    }

    public func LoadOutfit(name: CName) -> Bool {
        if this.IsBlocked() {
            return false;
        }

        let outfit = this.m_state.GetOutfit(name);

        if !IsDefined(outfit) {
            return false;
        }

        this.ActivateWithoutClone();

        let slots = this.GetOutfitSlots();

        for part in outfit.GetParts() {
            let itemID = part.GetItemID();
            let slotID = this.GetItemSlot(itemID); // part.GetSlotID()

            this.EquipItem(itemID, slotID);
            ArrayRemove(slots, slotID);
        }

        for slotID in slots {
            this.UnequipSlot(slotID);
        }

        this.TriggerActivationEvent(name);

        return true;
    }

    public func AddOutfit(name: CName, parts: array<ref<OutfitPart>>, opt overwrite: Bool) -> Bool {
        return this.m_state.SaveOutfit(name, parts, overwrite, this.GetTimestamp());
    }

    public func SaveOutfit(name: CName, opt overwrite: Bool) -> Bool {
        this.Activate();

        return this.m_state.SaveOutfit(name, overwrite, this.GetTimestamp());
    }

    public func CopyOutfit(name: CName, from: CName) -> Bool {
        return this.m_state.CopyOutfit(name, from, this.GetTimestamp());
    }

    public func DeleteOutfit(name: CName) -> Bool {
        return this.m_state.DeleteOutfit(name);
    }

    public func DeleteAllOutfits() -> Bool {
        this.TriggerOutfitListEvent();

        return this.m_state.DeleteAllOutfits();
    }

    public func GetOutfits() -> array<CName> {
        let outfits: array<CName>;
        
        for outfit in this.m_state.GetOutfits() {
            let index = 0;
            while index < ArraySize(outfits) && StrCmp(NameToString(outfit.GetName()), NameToString(outfits[index])) > 0 {
                index += 1;
            }
            ArrayInsert(outfits, index, outfit.GetName());
        }

        return outfits;
    }

    public func GetOutfitParts(name: CName) -> array<ref<OutfitPart>> {
		return this.m_state.GetOutfitParts(name);
	}

    public func GiveItem(recordID: TweakDBID) -> ItemID {
        let itemID: ItemID;
        let itemData = this.m_transactionSystem.GetItemDataByTDBID(this.m_player, recordID);

        if IsDefined(itemData) {
            itemID = itemData.GetID();
        } else {
            itemID = ItemID.FromTDBID(recordID);
            this.m_transactionSystem.GiveItem(this.m_player, itemID, 1, TweakDBInterface.GetItemRecord(recordID).Tags());
        }

        return itemID;
    }

    public func GiveItem(itemID: ItemID) -> ItemID {
        let recordID: TweakDBID;
        let itemData = this.m_transactionSystem.GetItemData(this.m_player, itemID);

        if IsDefined(itemData) {
            itemID = itemData.GetID();
        } else {
            recordID = ItemID.GetTDBID(itemID);
            itemData = this.m_transactionSystem.GetItemDataByTDBID(this.m_player, recordID);

            if IsDefined(itemData) {
                itemID = itemData.GetID();
            } else {
                this.m_transactionSystem.GiveItem(this.m_player, itemID, 1, TweakDBInterface.GetItemRecord(recordID).Tags());
            }
        }

        return itemID;
    }

    public func EquipPuppetItem(puppet: ref<gamePuppet>, itemID: ItemID) {
        let slotID = this.GetItemSlot(itemID);
        let previewID = this.m_transactionSystem.CreatePreviewItemID(itemID);

        this.m_transactionSystem.GivePreviewItemByItemID(puppet, itemID);
        this.m_transactionSystem.AddItemToSlot(puppet, slotID, previewID, true);
    }

    public func UnequipPuppetItem(puppet: ref<gamePuppet>, itemID: ItemID) {
        let slotID = this.GetItemSlot(itemID);
        let previewID = this.m_transactionSystem.CreatePreviewItemID(itemID);

        this.m_transactionSystem.RemoveItemFromSlot(puppet, slotID);
        this.m_transactionSystem.RemoveItem(puppet, previewID, 1);
    }

    public func EquipPuppetOutfit(puppet: ref<gamePuppet>, opt items: script_ref<array<ItemID>>) {
        this.EquipPuppetOutfit(puppet, this.m_state.IsActive(), items);
    }

    public func EquipPuppetOutfit(puppet: ref<gamePuppet>, useOutfit: Bool, opt items: script_ref<array<ItemID>>) {
        if useOutfit {
            this.EquipPuppetParts(puppet, this.m_state.GetParts(), items);
        } else {
            this.EquipPuppetParts(puppet, this.GetEquipmentParts(), items);
        }
    }

    public func EquipPuppetOutfit(puppet: ref<gamePuppet>, outfitName: CName, opt items: script_ref<array<ItemID>>) {
        if NotEquals(outfitName, n"") {
            let outfit = this.m_state.GetOutfit(outfitName);
            if IsDefined(outfit) {
                this.EquipPuppetParts(puppet, outfit.GetParts(), items);
            }
        } else {
            this.EquipPuppetParts(puppet, this.GetEquipmentParts(), items);
        }
    }

    private func EquipPuppetParts(puppet: ref<gamePuppet>, parts: array<ref<OutfitPart>>, opt items: script_ref<array<ItemID>>) {
        for slotID in this.m_managedSlots {
            this.m_transactionSystem.RemoveItemFromSlot(puppet, slotID);
        }

        for part in parts {
            let itemID = part.GetItemID();
            let slotID = part.GetSlotID();

            if !this.IsBaseSlot(slotID) {
                slotID = this.GetItemSlot(itemID);
            }

            let previewID = this.m_transactionSystem.CreatePreviewItemID(itemID);
            this.m_transactionSystem.GivePreviewItemByItemID(puppet, itemID);
            this.m_transactionSystem.AddItemToSlot(puppet, slotID, previewID, true);

            ArrayPush(Deref(items), previewID);
        }
    }

    public func UpdatePuppetFromBlackboard(puppet: ref<gamePuppet>) -> Bool {
        if !IsDefined(puppet) {
            return false;
        }

        let modifiedArea = FromVariant<SPaperdollEquipData>(this.m_equipmentBlackboard.GetVariant(this.m_equipmentDef.lastModifiedArea));
        let slotID = modifiedArea.placementSlot;

        if !this.IsOutfitSlot(slotID) {
            return this.IsBaseSlot(slotID) ? this.m_state.IsActive() : false;
        }

        let itemID = FromVariant<ItemID>(this.m_equipmentBlackboard.GetVariant(this.m_equipmentDef.itemEquipped));
        let itemObject = this.m_transactionSystem.GetItemInSlot(puppet, slotID);

        if IsDefined(itemObject) {
            let previewID = itemObject.GetItemID();

            if Equals(previewID, itemID) {
                return true;
            }

            this.m_transactionSystem.RemoveItemFromSlot(puppet, slotID);
            this.m_transactionSystem.RemoveItem(puppet, previewID, 1);
        }

        if ItemID.IsValid(itemID) && modifiedArea.equipped {
            let previewID = this.m_transactionSystem.CreatePreviewItemID(itemID);
            this.m_transactionSystem.GivePreviewItemByItemID(puppet, itemID);
            this.m_transactionSystem.AddItemToSlot(puppet, slotID, previewID, true);
        }

        return true;
    }

    public func IsBaseSlot(slotID: TweakDBID) -> Bool {
        return ArrayContains(this.m_baseSlots, slotID);
    }

    public func IsOutfitSlot(slotID: TweakDBID) -> Bool {
        return ArrayContains(this.m_outfitSlots, slotID);
    }

    public func IsManagedSlot(slotID: TweakDBID) -> Bool {
        return ArrayContains(this.m_managedSlots, slotID);
    }

    public func IsManagedArea(area: gamedataEquipmentArea) -> Bool {
        return ArrayContains(this.m_managedAreas, area);
    }


    public func GetOutfitSlots() -> array<TweakDBID> {
        return this.m_outfitSlots;
    }

    public func GetUsedSlots() -> array<TweakDBID> {
        let slots: array<TweakDBID>;
        for part in this.m_state.GetParts() {
            ArrayPush(slots, part.GetSlotID());
        }
        return slots;
    }

    public func GetSlotName(slotID: TweakDBID) -> String {
        let key = TweakDBInterface.GetAttachmentSlotRecord(slotID).LocalizedName();
        let name = GetLocalizedTextByKey(StringToName(key));
        return NotEquals(name, "") ? name : key;
    }

    public func GetItemName(itemID: ItemID) -> String {
        return ItemID.IsValid(itemID) ? GetLocalizedTextByKey(TweakDBInterface.GetItemRecord(ItemID.GetTDBID(itemID)).DisplayName()) : "";
    }

    public static func GetInstance(game: GameInstance) -> ref<OutfitSystem> {
        return GameInstance.GetScriptableSystemsContainer(game).Get(n"EquipmentEx.OutfitSystem") as OutfitSystem;
    }
}

public class PlayerSlotsCallback extends AttachmentSlotsScriptCallback {
    private let m_system: wref<OutfitSystem>;

    public func OnItemEquipped(slotID: TweakDBID, itemID: ItemID) -> Void {
        if this.m_system.IsActive() && ItemID.IsValid(itemID) {
            if Equals(slotID, t"AttachmentSlots.Outfit") {
                this.m_system.Deactivate();
            }
        }
    }

    public func OnItemEquippedVisual(slotID: TweakDBID, itemID: ItemID) -> Void {
        if this.m_system.IsActive() && ItemID.IsValid(itemID) {
            if this.m_system.IsBaseSlot(slotID) {
                this.m_system.ReattachVisualInSlot(this.m_system.GetItemSlot(itemID));
            }
        }
    }

    public func OnItemUnequippedComplete(slotID: TweakDBID, itemID: ItemID) -> Void {
        if this.m_system.IsActive() && ItemID.IsValid(itemID) {
            if this.m_system.IsBaseSlot(slotID) {
                this.m_system.ReattachVisualInSlot(this.m_system.GetItemSlot(itemID));
            }
        }
    }

    public static func Create(system: ref<OutfitSystem>) -> ref<PlayerSlotsCallback> {
        let self = new PlayerSlotsCallback();
        self.m_system = system;

        return self;
    }
}

class DelayedRestoreCallback extends DelayCallback {
    private let m_system: wref<OutfitSystem>;

    public func Call() {
        this.m_system.AttachAllVisualsToSlots();
    }

    public static func Create(system: ref<OutfitSystem>) -> ref<DelayedRestoreCallback> {
        let self = new DelayedRestoreCallback();
        self.m_system = system;

        return self;
    }
}

class DelayedEquipCallback extends DelayCallback {
    private let m_system: wref<OutfitSystem>;
    private let m_itemID: ItemID;

    public func Call() {
        this.m_system.EquipItem(this.m_itemID);
    }

    public static func Create(system: ref<OutfitSystem>, itemID: ItemID) -> ref<DelayedEquipCallback> {
        let self = new DelayedEquipCallback();
        self.m_system = system;
        self.m_itemID = itemID;

        return self;
    }
}

class DelayedAttachCallback extends DelayCallback {
    private let m_transactionSystem: wref<TransactionSystem>;
    private let m_player: wref<GameObject>;
    private let m_slotID: TweakDBID;
    private let m_itemID: ItemID;

    public func Call() {
        this.m_transactionSystem.AddItemToSlot(this.m_player, this.m_slotID, this.m_itemID, true);
    }

    public static func Create(transactionSystem: wref<TransactionSystem>, player: wref<GameObject>, slotID: TweakDBID, itemID: ItemID) -> ref<DelayedAttachCallback> {
        let self = new DelayedAttachCallback();
        self.m_transactionSystem = transactionSystem;
        self.m_player = player;
        self.m_slotID = slotID;
        self.m_itemID = itemID;

        return self;
    }
}

public class PaperdollHelper extends ScriptableSystem {
    private let m_puppet: wref<gamePuppet>;
    private let m_preview: wref<inkInventoryPuppetPreviewGameController>;

    public func AddPreview(preview: ref<inkInventoryPuppetPreviewGameController>) {
        this.m_preview = preview;
    }

    public func GetPreview() -> wref<inkInventoryPuppetPreviewGameController> {
        return this.m_preview;
    }

    public func AddPuppet(puppet: ref<gamePuppet>) {
        this.m_puppet = puppet;
    }

    public func GetPuppet() -> wref<gamePuppet> {
        return this.m_puppet;
    }

    public static func GetInstance(game: GameInstance) -> ref<PaperdollHelper> {
        return GameInstance.GetScriptableSystemsContainer(game).Get(n"EquipmentEx.PaperdollHelper") as PaperdollHelper;
    }
}

public class ItemSourceUpdated extends Event {}

public class ViewManager extends ScriptableSystem {
    private persistent let m_state: ref<ViewState>;

    private func OnAttach() {
        if !IsDefined(this.m_state) {
            this.m_state = new ViewState();
            this.m_state.SetItemSource(WardrobeItemSource.InventoryAndStash);
        }
    }

    public func GetItemSource() -> WardrobeItemSource {
        return this.m_state.GetItemSource();
    }

    public func SetItemSource(source: WardrobeItemSource) {
        if NotEquals(this.m_state.GetItemSource(), source) {
            this.m_state.SetItemSource(source);
            this.TriggerItemSourceEvent();
        }
    }

    public func IsCollapsed(slotID: TweakDBID) -> Bool {
        return this.m_state.IsCollapsed(slotID);
    }

    public func SetCollapsed(slotID: TweakDBID, state: Bool) {
        this.m_state.SetCollapsed(slotID, state);
    }

    public func SetCollapsed(state: Bool) {
        if state {
            let outfitSystem = OutfitSystem.GetInstance(this.GetGameInstance());
            this.m_state.SetCollapsed(outfitSystem.GetOutfitSlots());
        } else {
            this.m_state.SetCollapsed([]);
        }        
    }

    public func ToggleCollapsed(slotID: TweakDBID) {
        this.m_state.ToggleCollapsed(slotID);
    }

    public func ToggleCollapsed() {
        let outfitSystem = OutfitSystem.GetInstance(this.GetGameInstance());
        let outfitSlots = outfitSystem.GetOutfitSlots();
        let collapsedSlots = this.m_state.GetCollapsed();

        this.SetCollapsed(ArraySize(outfitSlots) != ArraySize(collapsedSlots));
    }

    private func TriggerItemSourceEvent() {
        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(new ItemSourceUpdated());
    }

    public static func GetInstance(game: GameInstance) -> ref<ViewManager> {
        return GameInstance.GetScriptableSystemsContainer(game).Get(n"EquipmentEx.ViewManager") as ViewManager;
    }
}

enum WardrobeItemSource {
    WardrobeStore = 0,
    InventoryAndStash = 1,
    InventoryOnly = 2
}

class ViewState {
    private persistent let m_itemSource: WardrobeItemSource;
    private persistent let m_collapsedSlots: array<TweakDBID>;

    public func GetItemSource() -> WardrobeItemSource {
        return this.m_itemSource;
    }

    public func SetItemSource(source: WardrobeItemSource) {
        this.m_itemSource = source;
    }

    public func GetCollapsed() -> array<TweakDBID> {
        return this.m_collapsedSlots;
    }

    public func IsCollapsed(slotID: TweakDBID) -> Bool {
        return ArrayContains(this.m_collapsedSlots, slotID);
    }
    
    public func SetCollapsed(slotID: TweakDBID, state: Bool) {
        if (state) {
            if !ArrayContains(this.m_collapsedSlots, slotID) {
                ArrayPush(this.m_collapsedSlots, slotID);
            }
        } else {
            ArrayRemove(this.m_collapsedSlots, slotID);
        }
    }

    public func ToggleCollapsed(slotID: TweakDBID) {
        this.SetCollapsed(slotID, !ArrayContains(this.m_collapsedSlots, slotID));
    }
    
    public func SetCollapsed(slots: array<TweakDBID>) {
        this.m_collapsedSlots = slots;
    }
}

struct RecordSlotMapping {
    public let slotID: TweakDBID;
    public let recordIDs: array<TweakDBID>;
}

struct EntityNameSlotMapping {
    public let slotID: TweakDBID;
    public let entityName: CName;
}

struct AppearanceNameSlotMapping {
    public let slotID: TweakDBID;
    public let appearanceTokens: array<String>;
}

struct EquipmentAreaSlotMapping {
    public let slotID: TweakDBID;
    public let equipmentAreas: array<TweakDBID>;
}

struct PriceModifierSlotMapping {
    public let slotID: TweakDBID;
    public let priceModifiers: array<TweakDBID>;
}

struct SlotMappingMatch {
    public let slotID: TweakDBID;
    public let score: Int32;
}

class OutfitSlotMatcher {
    private let m_recordMappings: array<RecordSlotMapping>;
    private let m_entityMappings: array<EntityNameSlotMapping>;
    private let m_appearanceMappings: array<AppearanceNameSlotMapping>;
    private let m_equipmentMappings: array<EquipmentAreaSlotMapping>;
    private let m_priceMappings: array<PriceModifierSlotMapping>;
    private let m_ignoredEntities: array<CName>;

    public func MapRecords(mappings: array<RecordSlotMapping>) {
        this.m_recordMappings = mappings;
    }

    public func MapEntities(mappings: array<EntityNameSlotMapping>) {
        this.m_entityMappings = mappings;
    }

    public func MapAppearances(mappings: array<AppearanceNameSlotMapping>) {
        this.m_appearanceMappings = mappings;
    }

    public func MapEquipmentAreas(mappings: array<EquipmentAreaSlotMapping>) {
        this.m_equipmentMappings = mappings;
    }

    public func MapPrices(mappings: array<PriceModifierSlotMapping>) {
        this.m_priceMappings = mappings;
    }

    public func IgnoreEntities(ignores: array<CName>) {
        this.m_ignoredEntities = ignores;
    }
    
    public func Match(item: ref<Clothing_Record>) -> TweakDBID {
        if Equals(item.AppearanceName(), n"") {
            return TDBID.None();
        }

        let entityName = item.EntityName();

        if ArrayContains(this.m_ignoredEntities, entityName) {
            return TDBID.None();
        }

        let recordID = item.GetID();
        let appearanceName = NameToString(item.AppearanceName());
        let priceModifiers = TweakDBInterface.GetForeignKeyArray(item.GetID() + t".buyPrice");
        let equipmentArea = item.EquipArea().GetID();

        for mapping in this.m_recordMappings {
            if ArrayContains(mapping.recordIDs, recordID) {
                return mapping.slotID;
            }
        }

        for mapping in this.m_appearanceMappings {
            for appearanceToken in mapping.appearanceTokens {
                if Equals(appearanceName, appearanceToken) {
                    return mapping.slotID;
                }
            }
        }

        let match: SlotMappingMatch;
        for mapping in this.m_appearanceMappings {
            for appearanceToken in mapping.appearanceTokens {
                if StrFindFirst(appearanceName, appearanceToken) >= 0 {
                    if StrLen(appearanceToken) > match.score {
                        match.score = StrLen(appearanceToken);
                        match.slotID = mapping.slotID;
                    }
                }
            }
        }
        if match.score > 0 {
            return match.slotID;
        }

        for mapping in this.m_priceMappings {
            for priceModifier in mapping.priceModifiers {
                if ArrayContains(priceModifiers, priceModifier) {
                    return mapping.slotID;
                }
            }
        }

        for mapping in this.m_equipmentMappings {
            if ArrayContains(mapping.equipmentAreas, equipmentArea) {
                return mapping.slotID;
            }
        }

        for mapping in this.m_entityMappings {
            if Equals(entityName, mapping.entityName) {
                return mapping.slotID;
            }
        }

        return TDBID.None();
    }

    public static func Create() -> ref<OutfitSlotMatcher> {
        return new OutfitSlotMatcher();
    }
}

class OutfitTweakHelper {
    public static func PrepareCustomSlotMatcher() -> ref<OutfitSlotMatcher> {
        let slotMatcher = OutfitSlotMatcher.Create();

        slotMatcher.IgnoreEntities([
            n"player_head_item",
            n"player_face_item",
            n"player_inner_torso_item",
            n"player_outer_torso_item",
            n"player_legs_item",
            n"player_feet_item",
            n"player_outfit_item"
        ]);

        slotMatcher.MapPrices([
            PriceModifierSlotMapping(t"OutfitSlots.Glasses", [t"Price.Glasses", t"Price.Visor"]),
            PriceModifierSlotMapping(t"OutfitSlots.Wreath", [t"Price.TechFaceClothing"]),
            PriceModifierSlotMapping(t"OutfitSlots.LegsOuter", [t"Price.Skirt"])
        ]);

        slotMatcher.MapEquipmentAreas([
            EquipmentAreaSlotMapping(t"OutfitSlots.Head", [t"EquipmentArea.HeadArmor"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.Mask", [t"EquipmentArea.FaceArmor"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.TorsoInner", [t"EquipmentArea.InnerChest"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.TorsoOuter", [t"EquipmentArea.ChestArmor"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.LegsMiddle", [t"EquipmentArea.LegArmor"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.Feet", [t"EquipmentArea.Feet"]),
            EquipmentAreaSlotMapping(t"OutfitSlots.BodyOuter", [t"EquipmentArea.Outfit"])
        ]);

        return slotMatcher;
    }
    
    public static func PrepareOriginalSlotMatcher() -> ref<OutfitSlotMatcher> {
        let slotMatcher = OutfitSlotMatcher.Create();


        slotMatcher.MapEntities([
            EntityNameSlotMapping(t"OutfitSlots.Head", n"player_head_item"),
            EntityNameSlotMapping(t"OutfitSlots.Mask", n"player_face_item"),
            EntityNameSlotMapping(t"OutfitSlots.TorsoInner", n"player_inner_torso_item"),
            EntityNameSlotMapping(t"OutfitSlots.TorsoOuter", n"player_outer_torso_item"),
            EntityNameSlotMapping(t"OutfitSlots.LegsMiddle", n"player_legs_item"),
            EntityNameSlotMapping(t"OutfitSlots.Feet", n"player_feet_item"),
            EntityNameSlotMapping(t"OutfitSlots.BodyMiddle", n"player_outfit_item"),
            EntityNameSlotMapping(t"OutfitSlots.BodyMiddle", n"player_outfit_item_ep1")
        ]);

        slotMatcher.MapAppearances([
            AppearanceNameSlotMapping(t"OutfitSlots.Glasses", ["f1_tech_01_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.Wreath", ["f1_tech_02_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.Balaclava", ["h1_balaclava_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoUnder", ["t1_undershirt_02_", "t1_undershirt_03_", "t1_shirt_01_", "t1_shirt_02_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoInner", ["t1_undershirt_01_", "t1_tshirt_", "t1_formal_", "set_01_fixer_01_t1_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoInner", ["t2_dress_01_", "t2_jacket_16_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoMiddle", ["t1_shirt_03_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoMiddle", ["t2_dress_", "t2_shirt_", "t2_vest_", "t2_formal_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.TorsoAux", ["t2_vest_01_", "t2_vest_02_", "t2_vest_03_", "t2_vest_04_", "t2_vest_06_", "t2_vest_07_", "t2_vest_08_", "t2_vest_10_", "t2_vest_12_", "t2_vest_16_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.LegsOuter", ["l1_shorts_03_", "l1_shorts_04_", "l1_shorts_05_", "set_01_fixer_01_l1_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.LegsOuter", ["l1_pants_04_", "l1_pants_05_", "l1_pants_06_", "l1_pants_07_", "l1_pants_08_", "l1_pants_09_", "l1_pants_10_", "l1_pants_11_", "l1_pants_12_", "l1_pants_13_", "l1_pants_14_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.BodyUnder", ["t1_jumpsuit_", "set_01_netrunner_01_t1_"]),
            AppearanceNameSlotMapping(t"OutfitSlots.BodyMiddle", ["t2_jumpsuit_"]) // "outfit_02_q114_cyberspace_"
        ]);

        slotMatcher.MapPrices([
            PriceModifierSlotMapping(t"OutfitSlots.Mask", [t"Price.Mask"]),
            PriceModifierSlotMapping(t"OutfitSlots.Glasses", [t"Price.Glasses", t"Price.Visor"]),
            PriceModifierSlotMapping(t"OutfitSlots.Wreath", [t"Price.TechFaceClothing"]),
            PriceModifierSlotMapping(t"OutfitSlots.LegsOuter", [t"Price.Skirt"])
        ]);

        slotMatcher.MapRecords([
            RecordSlotMapping(t"OutfitSlots.Glasses", [
                t"Items.Media_01_Set_Tech",
                t"Items.Techie_01_Set_Tech"
            ]),
            RecordSlotMapping(t"OutfitSlots.TorsoUnder", [
                t"Items.Media_01_Set_Shirt"
            ]),
            RecordSlotMapping(t"OutfitSlots.TorsoMiddle", [
                t"Items.Corporate_01_Set_FormalJacket",
                t"Items.Rockerboy_01_Set_Jacket"
            ]),
            RecordSlotMapping(t"OutfitSlots.TorsoAux", [
                t"Items.Media_01_Set_Vest",
                t"Items.SQ021_Wraiths_Vest",
                t"Items.Techie_01_Set_Vest"
            ]),
            RecordSlotMapping(t"OutfitSlots.LegsOuter", [
                t"Items.Cop_01_Set_Pants",
                t"Items.Media_01_Set_Pants",
                t"Items.Netrunner_01_Set_Pants",
                t"Items.Nomad_01_Set_Pants",
                t"Items.Q202_Epilogue_Pants",
                t"Items.Q203_Epilogue_Pants",
                t"Items.Q204_Epilogue_Pants",
                t"Items.Solo_01_Set_Pants",
                t"Items.Techie_01_Set_Pants"
            ])
        ]);

        return slotMatcher;
    }

    public static func BuildOutfitSlotMap(out outfitSlots: array<ExtraSlotConfig>) -> ref<inkIntHashMap> {
        let outfitMap = new inkIntHashMap();
        let index = 0;
        for outfitSlot in outfitSlots {
            outfitMap.Insert(TDBID.ToNumber(outfitSlot.slotID), index);
            index = index + 1;
        }
        return outfitMap;
    }
}

class PatchCustomItems extends ScriptableTweak {
    protected func OnApply() -> Void {
        let batch = TweakDBManager.StartBatch();
        let outfitSlots = OutfitConfig.OutfitSlots();
        let outfitMap = OutfitTweakHelper.BuildOutfitSlotMap(outfitSlots);
        let slotMatcher = OutfitTweakHelper.PrepareCustomSlotMatcher();

        for record in TweakDBInterface.GetRecords(n"Clothing_Record") {
            let item = record as Clothing_Record;
            let placementSlots = TweakDBInterface.GetForeignKeyArray(item.GetID() + t".placementSlots");

            if ArraySize(placementSlots) == 1 {
                let outfitSlotID = slotMatcher.Match(item);
                if TDBID.IsValid(outfitSlotID) {
                    let outfitHash = TDBID.ToNumber(outfitSlotID);
                    if outfitMap.KeyExist(outfitHash) {
                        let outfitIndex = outfitMap.Get(outfitHash);
                        let outfitSlot = outfitSlots[outfitIndex];
                        if !ArrayContains(placementSlots, outfitSlot.slotID) {
                            ArrayPush(placementSlots, outfitSlot.slotID);
                            batch.SetFlat(item.GetID() + t".placementSlots", placementSlots);
                            batch.UpdateRecord(item.GetID());
                        }
                    }
                }
            }
        }

        batch.Commit();

        for record in TweakDBInterface.GetRecords(n"Clothing_Record") {
            let item = record as Clothing_Record;
            let placementSlots = TweakDBInterface.GetForeignKeyArray(item.GetID() + t".placementSlots");
            let garmentOffset = item.GarmentOffset();

            if (garmentOffset == 0 || DevMode()) && ArraySize(placementSlots) > 1 {
                let outfitSlotID = ArrayLast(placementSlots);
                if TDBID.IsValid(outfitSlotID) {
                    let outfitHash = TDBID.ToNumber(outfitSlotID);
                    if outfitMap.KeyExist(outfitHash) {
                        let outfitIndex = outfitMap.Get(outfitHash);
                        let outfitSlot = outfitSlots[outfitIndex];
                        batch.SetFlat(item.GetID() + t".garmentOffset", outfitSlot.garmentOffset);
                        batch.UpdateRecord(item.GetID());
                    }
                }
            }
        }

        batch.Commit();
    }
}

class PatchOriginaltems extends ScriptableTweak {
    protected func OnApply() -> Void {
        let batch = TweakDBManager.StartBatch();
        let outfitSlots = OutfitConfig.OutfitSlots();
        let outfitMap = OutfitTweakHelper.BuildOutfitSlotMap(outfitSlots);
        let slotMatcher = OutfitTweakHelper.PrepareOriginalSlotMatcher();

        for record in TweakDBInterface.GetRecords(n"Clothing_Record") {
            let item = record as Clothing_Record;
            let placementSlots = TweakDBInterface.GetForeignKeyArray(item.GetID() + t".placementSlots");
            let garmentOffset = item.GarmentOffset();

            let outfitSlotID: TweakDBID;
            if ArraySize(placementSlots) == 1 || DevMode() {
                outfitSlotID = slotMatcher.Match(item);
            } else {
                outfitSlotID = ArrayLast(placementSlots);
            }

            if TDBID.IsValid(outfitSlotID) {
                let updated = false;

                let outfitHash = TDBID.ToNumber(outfitSlotID);
                if outfitMap.KeyExist(outfitHash) {
                    let outfitIndex = outfitMap.Get(outfitHash);
                    let outfitSlot = outfitSlots[outfitIndex];

                    if NotEquals(ArrayLast(placementSlots), outfitSlot.slotID) {
                        ArrayRemove(placementSlots, outfitSlot.slotID);
                        ArrayPush(placementSlots, outfitSlot.slotID);
                        if garmentOffset == 0 || DevMode() {
                            garmentOffset = outfitSlot.garmentOffset;
                        }
                        updated = true;
                    }
                }

                if updated {
                    batch.SetFlat(item.GetID() + t".placementSlots", placementSlots);
                    batch.SetFlat(item.GetID() + t".garmentOffset", garmentOffset);
                    batch.UpdateRecord(item.GetID());
                }
            }
        }

        batch.Commit();
    }
}

class RegisterOutfitSlots extends ScriptableTweak {
    protected func OnApply() -> Void {
        let batch = TweakDBManager.StartBatch();
        let outfitSlots = OutfitConfig.OutfitSlots();

        for outfitSlot in outfitSlots {
            batch.CreateRecord(outfitSlot.slotID, n"AttachmentSlot_Record");
            batch.SetFlat(outfitSlot.slotID + t".localizedName", outfitSlot.displayName);

            if ArraySize(outfitSlot.relatedSlotIDs) > 0 {
                batch.SetFlat(outfitSlot.slotID + t".parentSlot", outfitSlot.relatedSlotIDs[0]);
            }

            if ArraySize(outfitSlot.dependencySlotIDs) > 0 {
                batch.SetFlat(outfitSlot.slotID + t".dependencySlots", outfitSlot.dependencySlotIDs);
            }

            batch.UpdateRecord(outfitSlot.slotID);
            batch.RegisterName(outfitSlot.slotName);
        }

        let playerEntityTemplates = [
            r"base\\characters\\entities\\player\\player_wa_fpp.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_cutscene.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_cutscene_no_impostor.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_reflexion.ent",
            r"base\\characters\\entities\\player\\player_ma_fpp.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_cutscene.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_cutscene_no_impostor.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_reflexion.ent"
        ];

        let playerDisplayName = GetLocalizedTextByKey(TweakDBInterface.GetLocKeyDefault(t"Character.Player_Puppet_Base.displayName"));

        for record in TweakDBInterface.GetRecords(n"Character_Record") {
            let character = record as Character_Record;
            if ArrayContains(playerEntityTemplates, character.EntityTemplatePath()) || Equals(GetLocalizedTextByKey(character.DisplayName()), playerDisplayName) {
                let characterSlots = TweakDBInterface.GetForeignKeyArray(character.GetID() + t".attachmentSlots");
                if ArrayContains(characterSlots, t"AttachmentSlots.Chest") {
                    for outfitSlot in outfitSlots {
                        if !ArrayContains(characterSlots, outfitSlot.slotID) {
                            ArrayPush(characterSlots, outfitSlot.slotID);
                        }
                    }

                    batch.SetFlat(character.GetID() + t".attachmentSlots", characterSlots);
                    batch.UpdateRecord(character.GetID());
                }
            }
        }

        batch.Commit();
    }
}

public class ArchivePopup {
    public static func Show(controller: ref<worlduiIGameController>) -> ref<inkGameNotificationToken> {
        return GenericMessageNotification.Show(
            controller, 
            GetLocalizedText("LocKey#11447"), 
            "Equipment-EX has detected an issue:\n" + 
            "- archive/pc/mod/EquipmentEx.archive is missing\n\n" +
            "Possible solutions:\n" +
            "- Reinstall the mod from the original distribution\n" +
            "- If you installed it as REDmod, make sure mods are enabled\n", 
            GenericMessageNotificationType.OK
        );
    }
}

class CollapseButtonClick extends Event {
    public let collapse: Bool;
    public let action: ref<inkActionName>;
}

class CollapseButton extends inkCustomController {
    protected let m_isFlipped: Bool;
    protected let m_isCollapse: Bool;

    protected let m_bg: wref<inkImage>;
    protected let m_frame: wref<inkImage>;
    protected let m_icon: wref<inkCompoundWidget>;

    protected cb func OnCreate() {
        let root = new inkCanvas();
        root.SetSize(110.0, 80.0);
        root.SetAnchorPoint(Vector2(0.5, 0.5));
        root.SetInteractive(true);

        let bg = new inkImage();
        bg.SetName(n"bg");
        bg.SetAnchor(inkEAnchor.Fill);
        bg.SetNineSliceScale(true);
        bg.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        bg.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        bg.BindProperty(n"tintColor", n"FilterButton.backgroundColor");
        bg.BindProperty(n"opacity", n"FilterButton.backgroundOpacity");
        bg.Reparent(root);

        let frame = new inkImage();
        frame.SetName(n"frame");
        frame.SetAnchor(inkEAnchor.Fill);
        frame.SetNineSliceScale(true);
        frame.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        frame.SetTexturePart(n"tooltip_map_fg");
        frame.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        frame.BindProperty(n"tintColor", n"FilterButton.frameColor");
        frame.BindProperty(n"opacity", n"FilterButton.frameOpacity");
        frame.Reparent(root);

        let icon = new inkVerticalPanel();
        icon.SetAnchor(inkEAnchor.Centered);
        icon.SetAnchorPoint(Vector2(0.5, 0.5));
        icon.Reparent(root);

        let arrowScale = 0.4;
        let arrowSize = Vector2(44.0 * arrowScale, 38.0 * arrowScale);

        let arrowUp = new inkImage();
        arrowUp.SetName(n"arrowUp");
        arrowUp.SetHAlign(inkEHorizontalAlign.Center);
        arrowUp.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        arrowUp.SetTexturePart(n"arrow_rect_bg");
        arrowUp.SetSize(arrowSize);
        arrowUp.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        arrowUp.BindProperty(n"tintColor", n"FilterButton.iconColor");
        arrowUp.Reparent(icon);

        let line = new inkRectangle();
        line.SetHAlign(inkEHorizontalAlign.Center);
        line.SetSize(Vector2(arrowSize.X + 12.0, 2.0));
        line.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        line.BindProperty(n"tintColor", n"FilterButton.iconColor");
        line.Reparent(icon);

        let arrowDown = new inkImage();
        arrowDown.SetName(n"arrowDown");
        arrowDown.SetHAlign(inkEHorizontalAlign.Center);
        arrowDown.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        arrowDown.SetTexturePart(n"arrow_down_bg");
        arrowDown.SetSize(arrowSize);
        arrowDown.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        arrowDown.BindProperty(n"tintColor", n"FilterButton.iconColor");
        arrowDown.Reparent(icon);

        this.m_bg = bg;
        this.m_frame = frame;
        this.m_icon = icon;

        this.SetRootWidget(root);
        this.ApplyCollapseState();
        this.ApplyFlippedState();
    }

    protected cb func OnInitialize() {
        this.RegisterToCallback(n"OnClick", this, n"OnClick");
        this.RegisterToCallback(n"OnHoverOver", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnHoverOut", this, n"OnHoverOut");
    }

    protected cb func OnClick(evt: ref<inkPointerEvent>) {
        this.TriggerClickEvent(evt.GetActionName());
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        this.GetRootWidget().SetState(n"Hover");
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        this.GetRootWidget().SetState(n"Default");
    }

    protected func ApplyCollapseState() {
        this.m_icon.SetChildOrder(this.m_isCollapse ? inkEChildOrder.Backward : inkEChildOrder.Forward);
        this.m_icon.SetChildMargin(this.m_isCollapse ? inkMargin(0.0, 3.0, 0.0, 3.0) : inkMargin(0.0, 3.0, 0.0, 3.0));
    }

    protected func ApplyFlippedState() {
        this.m_bg.SetTexturePart(this.m_isFlipped ? n"cell_flip_bg" : n"cell_bg");
        this.m_frame.SetBrushMirrorType(this.m_isFlipped ? inkBrushMirrorType.Horizontal : inkBrushMirrorType.NoMirror);
    }

    protected func TriggerClickEvent(action: ref<inkActionName>) {
        let evt = new CollapseButtonClick();
        evt.collapse = this.m_isCollapse;
        evt.action = action;

        let uiSystem = GameInstance.GetUISystem(this.GetGame());
        uiSystem.QueueEvent(evt);
    }

    public func SetCollapse(isCollapse: Bool) {
        this.m_isCollapse = isCollapse;

        this.ApplyCollapseState();
    }

    public func SetFlipped(isFlipped: Bool) {
        this.m_isFlipped = isFlipped;

        this.ApplyFlippedState();
    }

    public static func Create() -> ref<CollapseButton> {
        let self = new CollapseButton();
        self.CreateInstance();

        return self;
    }

    func OnReparent(parent: ref<inkCompoundWidget>) {}
}

public class ConflictsPopup {
    public static func Show(controller: ref<inkGameController>) -> ref<inkGameNotificationToken> {
        let game = controller.GetPlayerControlledObject().GetGame();
        let conflicts: array<String>;
        CompatibilityManager.CheckConflicts(game, conflicts);

        let conflictStr: String;
        for conflict in conflicts {
            conflictStr += "- " + conflict + "\n";
        }
        
        let params = new inkTextParams();
        params.AddString("conflicts", conflictStr);

        return GenericMessageNotification.Show(
            controller, 
            GetLocalizedText("LocKey#11447"), 
            GetLocalizedTextByKey(n"UI-EquipmentEx-NotificationConflicts"), 
            params,
            GenericMessageNotificationType.OK
        );
    }
}

class InventoryGridItemData extends VendorUIInventoryItemData {
    public let Parent: wref<InventoryGridSlotData>;
    public let IsVisible: Bool;
}

class InventoryGridSlotData extends VendorUIInventoryItemData {
    public let Children: array<ref<InventoryGridItemData>>;
    public let TotalItems: Int32;
    public let VisibleItems: Int32;
    public let IsCollapsed: Bool;

    protected func GetActiveItem() -> wref<InventoryGridItemData> {
        for uiItem in this.Children {
            if uiItem.Item.IsEquipped() {
                return uiItem;
            }
        }

        return null;
    }
}

class InventoryGridDataView extends BackpackDataView {
    private let m_filter: Bool;
    private let m_refresh: Bool;
    private let m_reverse: Bool;
    private let m_searchQuery: String;
    private let m_viewManager: wref<ViewManager>;

    public func SetViewManager(viewManager: wref<ViewManager>) {
        this.m_viewManager = viewManager;
    }

    public func SetCollapsed(state: Bool) {
        this.m_viewManager.SetCollapsed(state);
    }

    public func ToggleCollapsed() {
        this.m_viewManager.ToggleCollapsed();
    }

    public func ToggleCollapsed(slotID: TweakDBID) {
        this.m_viewManager.ToggleCollapsed(slotID);
    }

    public func SetSearchQuery(searchQuery: String) {
        this.m_searchQuery = UTF8StrLower(searchQuery);
    }

    public func UpdateView() {
        this.DisableSorting();
        this.m_filter = true;
        this.Filter();
        this.m_filter = false;
        this.Filter();
    }

    public func FilterItem(data: ref<IScriptable>) -> Bool {
        let uiItem = data as InventoryGridItemData;

        if IsDefined(uiItem) {
            if this.m_filter {
                uiItem.IsVisible = true;

                if Equals(this.m_itemFilterType, ItemFilterCategory.Clothes) {
                    if !uiItem.Item.IsEquipped() {
                        uiItem.IsVisible = false;
                    }
                }

                if NotEquals(this.m_searchQuery, "") {
                    let itemName = UTF8StrLower(GetLocalizedText(uiItem.Item.m_data.Name));
                    if !StrContains(itemName, this.m_searchQuery) {
                        uiItem.IsVisible = false;
                    }
                }
            }

            return uiItem.IsVisible && !uiItem.Parent.IsCollapsed;
        }

        let uiSlot = data as InventoryGridSlotData;

        if IsDefined(uiSlot) {
            if this.m_filter {
                uiSlot.IsCollapsed = this.m_viewManager.IsCollapsed(uiSlot.ItemData.SlotID);
            } else {
                uiSlot.TotalItems = ArraySize(uiSlot.Children);
                uiSlot.VisibleItems = 0;

                for uiChildData in uiSlot.Children {
                    if uiChildData.IsVisible {
                        uiSlot.VisibleItems += 1;
                    }
                }
            }

            return uiSlot.VisibleItems > 0;
        }

        return false;
    }
}

class InventoryGridTemplateClassifier extends inkVirtualItemTemplateClassifier {
    public func ClassifyItem(data: Variant) -> Uint32 {
        return IsDefined(FromVariant<ref<IScriptable>>(data) as InventoryGridSlotData) ? 1u : 0u;
    }
}

class InventoryGridItemController extends VendorItemVirtualController {
    protected cb func OnOutfitUpdated(evt: ref<OutfitUpdated>) {
        this.UpdateEquippedState();
    }

    protected cb func OnOutfitPartUpdated(evt: ref<OutfitPartUpdated>) {
        this.UpdateEquippedState();
    }

    protected func UpdateEquippedState() {
        this.m_itemViewController.NewUpdateEquipped(this.m_itemViewController.m_uiInventoryItem);
        this.m_itemViewController.NewUpdateLocked(this.m_itemViewController.m_uiInventoryItem);
    }
}

class InventoryGridSlotClick extends Event {
    public let slot: ref<InventoryGridSlotData>;
    public let action: ref<inkActionName>;
}

class InventoryGridSlotHoverOver extends Event {
    public let slot: ref<InventoryGridSlotData>;
}

class InventoryGridSlotHoverOut extends Event {
    public let slot: ref<InventoryGridSlotData>;
}

class InventoryGridSlotController extends inkVirtualCompoundItemController {
    private let m_uiSlot: ref<InventoryGridSlotData>;

    private let m_root: wref<inkCompoundWidget>;
    private let m_arrow: wref<inkImage>;
    private let m_slotName: wref<inkText>;
    private let m_itemName: wref<inkText>;
    private let m_itemCount: wref<inkText>;

    private let m_isToggled: Bool;
    private let m_isHovered: Bool;

    protected cb func OnInitialize() {
        this.m_root = this.GetRootCompoundWidget();

        let content = new inkVerticalPanel();
        content.SetName(n"content");
        content.SetHAlign(inkEHorizontalAlign.Left);
        content.SetVAlign(inkEVerticalAlign.Center);
        content.SetAnchor(inkEAnchor.CenterLeft);
        content.SetAnchorPoint(0.0, 0.5);
        content.SetMargin(inkMargin(28.0, 0.0, 0.0, 4.0));
        content.Reparent(this.m_root);

        let slotName = new inkText();
        slotName.SetName(n"slot_name");
        slotName.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        slotName.SetLetterCase(textLetterCase.UpperCase);
        slotName.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        slotName.BindProperty(n"tintColor", n"MainColors.Red");
        slotName.BindProperty(n"fontWeight", n"MainColors.BodyFontWeight");
        slotName.BindProperty(n"fontSize", n"MainColors.ReadableFontSize");
        slotName.SetFitToContent(true);
        slotName.Reparent(content);

        let itemName = new inkText();
        itemName.SetName(n"item_name");
        itemName.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        itemName.SetLetterCase(textLetterCase.UpperCase);
        itemName.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        itemName.BindProperty(n"tintColor", n"MainColors.Blue");
        itemName.BindProperty(n"fontSize", n"MainColors.ReadableXSmall");
        itemName.SetFitToContent(true);
        itemName.Reparent(content);

        let itemCount = new inkText();
        itemCount.SetName(n"item_count");
        itemCount.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        itemCount.SetLetterCase(textLetterCase.UpperCase);
        itemCount.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        itemCount.BindProperty(n"tintColor", n"MainColors.Grey");
        itemCount.BindProperty(n"fontSize", n"MainColors.ReadableXSmall");
        itemCount.SetFitToContent(true);
        itemCount.Reparent(content);

        let panel = new inkCanvas();
        panel.SetName(n"panel");       
        panel.SetAnchor(inkEAnchor.Fill);
        panel.SetMargin(inkMargin(0.0, 2.0, 0.0, 8.0));
        panel.Reparent(this.m_root);

        let bg1 = new inkImage();
        bg1.SetName(n"bg1");
        bg1.SetAnchor(inkEAnchor.Fill);
        bg1.SetAnchorPoint(Vector2(0.5, 0.5));
        bg1.SetNineSliceScale(true);
        bg1.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        bg1.SetTexturePart(n"item_bg");
        bg1.SetStyle(r"base\\gameplay\\gui\\common\\components\\slots_style.inkstyle");
        bg1.BindProperty(n"tintColor", n"ItemDisplay.background");
        bg1.BindProperty(n"opacity", n"ItemDisplay.backgroundOpacity");
        bg1.Reparent(panel);

        let bg2 = new inkImage();
        bg2.SetName(n"bg2");
        bg2.SetAnchor(inkEAnchor.Fill);
        bg2.SetAnchorPoint(Vector2(0.5, 0.5));
        bg2.SetNineSliceScale(true);
        bg2.SetNineSliceGrid(inkMargin(0.0, 0.0, 20.0, 0.0));
        bg2.SetAtlasResource(r"base\\gameplay\\gui\\fullscreen\\inventory\\atlas_inventory.inkatlas");
        bg2.SetTexturePart(n"texture_2slot_iconic");
        bg2.SetOpacity(0.03);
        bg2.SetStyle(r"base\\gameplay\\gui\\common\\components\\slots_style.inkstyle");
        bg2.BindProperty(n"tintColor", n"ItemDisplay.emptyLinesColor");
        bg2.Reparent(panel);

        let fg = new inkImage();
        fg.SetName(n"fg");
        fg.SetAnchor(inkEAnchor.Fill);
        fg.SetAnchorPoint(Vector2(0.5, 0.5));
        fg.SetNineSliceScale(true);
        fg.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        fg.SetTexturePart(n"item_fg");
        fg.SetStyle(r"base\\gameplay\\gui\\common\\components\\slots_style.inkstyle");
        fg.BindProperty(n"tintColor", n"ItemDisplay.borderColor");
        fg.BindProperty(n"opacity", n"ItemDisplay.borderOpacity");
        fg.Reparent(panel);

        let arrow = new inkImage();
        arrow.SetName(n"arrow");
        arrow.SetAnchor(inkEAnchor.CenterRight);
        arrow.SetAnchorPoint(Vector2(1.0, 0.5));
        arrow.SetMargin(inkMargin(0.0, 0.0, 40.0, 0.0));
        arrow.SetFitToContent(true);
        arrow.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        arrow.SetTexturePart(n"arrow_right_bg");
        arrow.SetStyle(r"base\\gameplay\\gui\\common\\components\\slots_style.inkstyle");
        arrow.BindProperty(n"tintColor", n"ItemDisplay.borderColor");
        arrow.BindProperty(n"opacity", n"ItemDisplay.borderOpacity");
        arrow.Reparent(panel);

        this.m_arrow = arrow;
        this.m_slotName = slotName;
        this.m_itemName = itemName;
        this.m_itemCount = itemCount;

        this.RegisterToCallback(n"OnClick", this, n"OnClick");
        this.RegisterToCallback(n"OnEnter", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnLeave", this, n"OnHoverOut");
    }

    protected cb func OnDataChanged(value: Variant) {
        this.m_uiSlot = FromVariant<ref<IScriptable>>(value) as InventoryGridSlotData;

        this.UpdateSlotInfo();
        this.UpdateActiveItem();
        this.UpdateState();
    }

    protected cb func OnOutfitUpdated(evt: ref<OutfitUpdated>) {
        this.UpdateActiveItem();
    }

    protected cb func OnOutfitPartUpdated(evt: ref<OutfitPartUpdated>) {
        if Equals(this.m_uiSlot.ItemData.SlotID, evt.slotID) {
            this.UpdateActiveItem();
        }
    }

    protected cb func OnClick(evt: ref<inkPointerEvent>) {
        this.TriggerClickEvent(evt.GetActionName());
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        this.UpdateState();
        this.TriggerHoverOverEvent();
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        this.UpdateState();
        this.TriggerHoverOutEvent();
    }

    protected func UpdateSlotInfo() {
        this.m_slotName.SetText(this.m_uiSlot.ItemData.CategoryName);

        let itemCount = GetLocalizedText("LocKey#53719") + ": ";
        if this.m_uiSlot.TotalItems != this.m_uiSlot.VisibleItems {
            itemCount += ToString(this.m_uiSlot.VisibleItems) + " / ";
        }
        itemCount += ToString(this.m_uiSlot.TotalItems);

        this.m_itemCount.SetText(itemCount);
    }

    protected func UpdateActiveItem() {
        let uiItem = this.m_uiSlot.GetActiveItem();
        
        if IsDefined(uiItem) {
            this.m_itemName.SetText(uiItem.Item.GetName());
            this.m_itemName.BindProperty(n"tintColor", n"MainColors.Blue");
        } else {
            this.m_itemName.SetText(GetLocalizedTextByKey(n"UI-Labels-EmptySlot"));
            this.m_itemName.BindProperty(n"tintColor", n"MainColors.Grey");
        }
    }

    protected func UpdateState() {
        this.m_arrow.SetRotation(this.m_uiSlot.IsCollapsed ? 0.0 : 90.0);
    }

    protected func TriggerClickEvent(action: ref<inkActionName>) {
        let evt = new InventoryGridSlotClick();
        evt.slot = this.m_uiSlot;
        evt.action = action;

        this.QueueEvent(evt);
    }

    protected func TriggerHoverOverEvent() {
        let evt = new InventoryGridSlotHoverOver();
        evt.slot = this.m_uiSlot;

        this.QueueEvent(evt);
    }

    protected func TriggerHoverOutEvent() {
        let evt = new InventoryGridSlotHoverOut();
        evt.slot = this.m_uiSlot;

        this.QueueEvent(evt);
    }
}

class ItemSourceOptionChange extends Event {
    public let value: WardrobeItemSource;
}

class ItemSourceOptionController extends inkButtonController {
    private let m_value: WardrobeItemSource;

    private let m_root: wref<inkCompoundWidget>;
    private let m_label: wref<inkText>;
    private let m_checkbox: wref<inkWidget>;
    private let m_selection: wref<inkWidget>;

    private let m_disabled: Bool;
    private let m_hovered: Bool;
    private let m_selected: Bool;

    protected cb func OnInitialize() {
        this.m_root = this.GetRootCompoundWidget();

        this.m_label = this.GetChildWidgetByPath(n"titleAndCheckbox/FilterName") as inkText;
        this.m_label.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        
        this.m_checkbox = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox");
        this.m_selection = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox/checkbox");

        this.RegisterToCallback(n"OnRelease", this, n"OnRelease");
        this.RegisterToCallback(n"OnEnter", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnLeave", this, n"OnHoverOut");       
    }

    protected cb func OnRelease(evt: ref<inkPointerEvent>) {
        if evt.IsAction(n"click") && !this.m_disabled && !this.m_selected {
            this.TriggerChangeEvent();
        }
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        if !this.m_disabled {
            this.m_hovered = true;

            this.UpdateState();
        }
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        if !this.m_disabled {
            this.m_hovered = false;    
                   
            this.UpdateState();
        }
    }

    protected cb func OnOptionChange(evt: ref<ItemSourceOptionChange>) {
        this.m_selected = Equals(this.m_value, evt.value);
        this.UpdateState();
    }

    protected func UpdateView() {
        this.m_root.SetSize(Vector2(this.m_label.GetDesiredWidth() + 170.0, 80.0));

        this.m_label.SetText(GetLocalizedText("UI-EquipmentEx-WardrobeItemSource-" + ToString(this.m_value)));
        this.m_label.BindProperty(n"fontStyle", n"MainColors.BodyFontWeight");
        this.m_label.BindProperty(n"fontSize", n"MainColors.ReadableSmall");

        this.m_checkbox.SetVisible(true);
        this.m_label.SetMargin(inkMargin(20, 0, 0, 0));

        this.GetChildWidgetByPath(n"titleAndCheckbox").SetMargin(inkMargin(0, 0, 0, 0));
        this.GetChildWidgetByPath(n"background").SetVisible(false);
    }

    protected func UpdateState() {
        this.m_selection.SetVisible(this.m_selected);

        if this.m_disabled {
            this.m_root.SetState(n"Default");
            this.m_root.SetOpacity(0.3);
        } else {
            this.m_root.SetOpacity(1.0);

            if this.m_hovered {
                this.m_root.SetState(n"Hover");
            }
            else {
                if this.m_selected {
                    this.m_root.SetState(n"Selected");
                }
                else {
                    this.m_root.SetState(n"Default");
                }
            }

            this.m_label.BindProperty(n"tintColor", this.m_selected ? n"MainColors.Blue" : n"MainColors.Red");
        }
    }

    protected func TriggerChangeEvent() {
        let evt = new ItemSourceOptionChange();
        evt.value = this.m_value;

        this.QueueEvent(evt);
    }

    public func SetData(value: WardrobeItemSource, selected: Bool) {
        this.m_value = value;
        this.m_selected = selected;

        this.UpdateView();
        this.UpdateState();
    }

    public func GetValue() -> WardrobeItemSource {
        return this.m_value;
    }

    public func IsSelected() -> Bool {
        return this.m_selected;
    }
}

enum OutfitListAction {
    Equip = 0,
    Unequip = 1,
    Save = 2
}

class OutfitListEntryData {
    public let Name: CName;
    public let Title: String;
    public let Color: CName;
    public let Action: OutfitListAction;
    public let Postition: Int32 = 2147483647;
    public let IsRemovable: Bool;
    public let IsSelectable: Bool;
    public let IsSelected: Bool;
}

class OutfitListDataView extends ScriptableDataView {
    public func UpdateView() {
        this.EnableSorting();
        this.Sort();
        this.DisableSorting();
    }

    public func SortItem(left: ref<IScriptable>, right: ref<IScriptable>) -> Bool {
        let leftEntry = left as OutfitListEntryData;
        let rightEntry = right as OutfitListEntryData;

        if leftEntry.Postition != rightEntry.Postition {
            return leftEntry.Postition < rightEntry.Postition;
        }
        
        return StrCmp(leftEntry.Title, rightEntry.Title) < 0;
    }
}

class OutfitListTemplateClassifier extends inkVirtualItemTemplateClassifier {
}

class OutfitListRefresh extends Event {}

class OutfitListEntryClick extends Event {
    public let entry: ref<OutfitListEntryData>;
    public let action: ref<inkActionName>;
}

class OutfitListEntryHoverOver extends Event {
    public let entry: ref<OutfitListEntryData>;
}

class OutfitListEntryHoverOut extends Event {
    public let entry: ref<OutfitListEntryData>;
}

class OutfitListEntryController extends inkVirtualCompoundItemController {
    private let m_data: ref<OutfitListEntryData>;

    private let m_root: wref<inkCompoundWidget>;
    private let m_label: wref<inkText>;
    private let m_checkbox: wref<inkWidget>;
    private let m_selection: wref<inkWidget>;

    private let m_isDisabled: Bool;
    private let m_isHovered: Bool;

    protected cb func OnInitialize() {
        this.m_root = this.GetRootCompoundWidget();

        this.m_label = this.GetChildWidgetByPath(n"titleAndCheckbox/FilterName") as inkText;
        this.m_label.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        
        this.m_checkbox = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox");
        this.m_selection = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox/checkbox");

        this.RegisterToCallback(n"OnRelease", this, n"OnRelease");
        this.RegisterToCallback(n"OnEnter", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnLeave", this, n"OnHoverOut");       
    }

    protected cb func OnDataChanged(value: Variant) {
        this.m_data = FromVariant<ref<IScriptable>>(value) as OutfitListEntryData;

        if IsDefined(this.m_data) {
            this.UpdateView();
            this.UpdateState();
        }
    }

    protected cb func OnRefresh(evt: ref<OutfitListRefresh>) {
        if IsDefined(this.m_data) {
            this.UpdateView();
            this.UpdateState();
        }
    }

    protected cb func OnRelease(evt: ref<inkPointerEvent>) {
        if !this.m_isDisabled {
            this.TriggerClickEvent(evt.GetActionName());
        }
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        if !this.m_isDisabled {
            this.m_isHovered = true;

            this.UpdateState();
            this.TriggerHoverOverEvent();
        }
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        if !this.m_isDisabled {
            this.m_isHovered = false;    
                   
            this.UpdateState();
            this.TriggerHoverOutEvent();
        }
    }

    protected func UpdateView() {
        this.m_label.SetText(this.m_data.Title);
        
        if NotEquals(this.m_data.Color, n"") {
            this.m_label.BindProperty(n"tintColor", this.m_data.Color);
        } else {
            this.m_label.BindProperty(n"tintColor", n"MainColors.Red");
        }

        if this.m_data.IsSelectable {
            this.m_checkbox.SetVisible(true);
            this.m_selection.SetVisible(this.m_data.IsSelected);
            this.m_label.SetMargin(inkMargin(30.0, 0.0, 0.0, 0.0));
        } else {
            this.m_checkbox.SetVisible(false);
            this.m_label.SetMargin(inkMargin(10.0, 0.0, 0.0, 0.0));
        }
    }

    protected func UpdateState() {
        if this.m_isDisabled {
            this.m_root.SetState(n"Default");
            this.m_root.SetOpacity(0.3);
        } else {
            this.m_root.SetOpacity(1.0);

            if this.m_isHovered {
                this.m_root.SetState(n"Hover");
            }
            else {
                if this.m_data.IsSelectable && this.m_data.IsSelected {
                    this.m_root.SetState(n"Selected");
                }
                else {
                    this.m_root.SetState(n"Default");
                }
            }
        }
    }

    protected func TriggerClickEvent(action: ref<inkActionName>) {
        let evt = new OutfitListEntryClick();
        evt.entry = this.m_data;
        evt.action = action;

        this.QueueEvent(evt);
    }

    protected func TriggerHoverOverEvent() {
        let evt = new OutfitListEntryHoverOver();
        evt.entry = this.m_data;

        this.QueueEvent(evt);
    }

    protected func TriggerHoverOutEvent() {
        let evt = new OutfitListEntryHoverOut();
        evt.entry = this.m_data;

        this.QueueEvent(evt);
    }

}

class OutfitManagerController extends inkLogicController {
    protected let m_player: wref<PlayerPuppet>;
    protected let m_outfitSystem: wref<OutfitSystem>;

    protected let m_wardrobeScreen: wref<WardrobeScreenController>;
    protected let m_buttonHints: wref<ButtonHints>;

    protected let m_outfitList: ref<inkVirtualListController>;
    protected let m_outfitListDataView: ref<OutfitListDataView>;
    protected let m_outfitListDataSource: ref<ScriptableDataSource>;
    protected let m_outfitListTemplateClassifier: ref<inkVirtualItemTemplateClassifier>;
    protected let m_outfitListScroll: wref<inkScrollController>;

    protected let m_popupToken: ref<inkGameNotificationToken>;
    protected let m_popupOutfit: CName;

    protected let m_enabled: Bool;

    protected cb func OnInitialize() -> Bool {
        this.InitializeLayout();
        this.InitializeList();
    }

    public func Setup(outfitSystem: wref<OutfitSystem>, wardrobeScreen: wref<WardrobeScreenController>, buttonHints: wref<ButtonHints>) {
        this.m_outfitSystem = outfitSystem;
        this.m_wardrobeScreen = wardrobeScreen;
        this.m_buttonHints = buttonHints;

        this.PopulateList();
        this.SetEnabled(true);
    }

    public func SetEnabled(enabled: Bool) {
        this.m_enabled = enabled;

        let widget = this.GetRootWidget();
        widget.SetInteractive(this.m_enabled);
        widget.SetOpacity(this.m_enabled ? 1.0 : 0.6);
    }

    protected func InitializeLayout() {
        this.m_outfitListScroll = this.GetChildWidgetByPath(n"scroll_wrapper").GetControllerByType(n"inkScrollController") as inkScrollController;

        let scrollArea = this.GetChildWidgetByPath(n"scroll_wrapper/scroll_area");
        scrollArea.RegisterToCallback(n"OnScrollChanged", this, n"OnScrollChanged");

        let header = new inkVerticalPanel();
        header.SetName(n"header");
        header.SetChildMargin(inkMargin(130.0, 0.0, 20.0, 0.0));
        header.Reparent(this.GetRootCompoundWidget());

        let title = new inkText();
        title = new inkText();
        title.SetName(n"title");
        title.SetText("LocKey#82878");
        title.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        title.SetLetterCase(textLetterCase.UpperCase);
        title.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        title.BindProperty(n"tintColor", n"MainColors.Red");
        title.BindProperty(n"fontStyle", n"MainColors.BodyFontWeight");
        title.BindProperty(n"fontSize", n"MainColors.ReadableFontSize");
        title.SetAnchor(inkEAnchor.TopLeft);
        title.SetMargin(inkMargin(0.0, 0.0, 0.0, 4.0));
        title.Reparent(header);

        let divider = new inkRectangle();
        divider.SetName(n"divider");
        divider.SetMargin(inkMargin(0.0, 0.0, 0.0, 15.0));
        divider.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        divider.BindProperty(n"tintColor", n"MainColors.Red");
        divider.SetOpacity(0.3);
        divider.SetSize(800.0, 3.0);
        divider.Reparent(header);
    }

    protected func InitializeList() {
        this.m_outfitListDataSource = new ScriptableDataSource();
        this.m_outfitListDataView = new OutfitListDataView();
        this.m_outfitListDataView.SetSource(this.m_outfitListDataSource);
        this.m_outfitListTemplateClassifier = new OutfitListTemplateClassifier();
        
        this.m_outfitList = this.GetChildWidgetByPath(n"scroll_wrapper/scroll_area/outfit_list").GetController() as inkVirtualListController;
        this.m_outfitList.SetClassifier(this.m_outfitListTemplateClassifier);
        this.m_outfitList.SetSource(this.m_outfitListDataView);
    }

    protected func PopulateList() {
        let saveAction = new OutfitListEntryData();
        saveAction.Title = GetLocalizedTextByKey(n"UI-Wardrobe-SaveSet");
        saveAction.Color = n"MainColors.ActiveBlue";
        saveAction.Action = OutfitListAction.Save;
        saveAction.Postition = 1;

        let unequipAction = new OutfitListEntryData();
        unequipAction.Title = GetLocalizedTextByKey(n"UI-Wardrobe-NoOutfit");
        unequipAction.Action = OutfitListAction.Unequip;
        unequipAction.IsSelectable = true;
        unequipAction.IsSelected = !this.m_outfitSystem.IsActive();
        unequipAction.Postition = 2;

        this.m_outfitListDataSource.Clear();
        this.m_outfitListDataSource.AppendItem(saveAction);
        this.m_outfitListDataSource.AppendItem(unequipAction);

        for outfitName in this.m_outfitSystem.GetOutfits() {
            this.AppendToList(outfitName, false);
        }

        this.m_outfitListDataView.UpdateView();
    }

    protected func AppendToList(outfitName: CName, opt updateView: Bool) {
        let outfitEntry = new OutfitListEntryData();
        outfitEntry.Name = outfitName;
        outfitEntry.Title = NameToString(outfitName);
        outfitEntry.IsRemovable = true;
        outfitEntry.IsSelectable = true;
        outfitEntry.IsSelected = this.m_outfitSystem.IsEquipped(outfitEntry.Name);

        this.m_outfitListDataSource.AppendItem(outfitEntry);

        if updateView {
            this.m_outfitListDataView.UpdateView();
        }
    }

    protected func RemoveFromList(outfitName: CName, opt updateView: Bool) {
        for data in this.m_outfitListDataSource.GetArray() {
            let outfitEntry = data as OutfitListEntryData;
            if Equals(outfitEntry.Name, outfitName)  {
                this.m_outfitListDataSource.RemoveItem(outfitEntry);

                if updateView {
                    this.m_outfitListDataView.UpdateView();
                }

                break;
            }
        }
    }

    protected func RefreshList(opt updateState: Bool) {
        if updateState {
            for data in this.m_outfitListDataSource.GetArray() {
                let outfitEntry = data as OutfitListEntryData;
                if outfitEntry.IsSelectable {
                    outfitEntry.IsSelected = this.m_outfitSystem.IsEquipped(outfitEntry.Name);
                }
            }
        }

        this.QueueEvent(new OutfitListRefresh());
    }

    protected cb func OnOutfitListEntryClick(evt: ref<OutfitListEntryClick>) {
        if !this.m_enabled {
            return;
        }

        if evt.action.IsAction(n"click") && this.AccessOutfitSystem() {
            this.PlaySound(n"Button", n"OnPress");

            switch evt.entry.Action {
                case OutfitListAction.Equip:
                    this.m_outfitSystem.LoadOutfit(evt.entry.Name);
                    break;
                case OutfitListAction.Unequip:
                    this.m_outfitSystem.Deactivate();
                    break;
                case OutfitListAction.Save:
                    this.ShowSaveOutfitPopup();
                    break;
            }

            this.ShowButtonHints(evt.entry);
            return;
        }

        if evt.action.IsAction(n"drop_item") && Equals(evt.entry.Action, OutfitListAction.Equip) && this.AccessOutfitSystem() {
            this.ShowDeleteOutfitPopup(evt.entry.Name);
        }
    }

    protected cb func OnOutfitListEntryItemHoverOver(evt: ref<OutfitListEntryHoverOver>) {
        this.ShowButtonHints(evt.entry);
    }

    protected cb func OnOutfitListEntryItemHoverOut(evt: ref<OutfitListEntryHoverOut>) {
        this.ShowButtonHints(null);
    }

    protected cb func ShowSaveOutfitPopup() {
        this.m_popupToken = GenericMessageNotification.ShowInput(this.m_wardrobeScreen, GetLocalizedTextByKey(n"UI-Wardrobe-SaveSet"), GetLocalizedTextByKey(n"UI-Wardrobe-NotificationSaveSet"), GenericMessageNotificationType.ConfirmCancel);
        this.m_popupToken.RegisterListener(this, n"OnSaveOutfitPopupClosed");
    }

    protected cb func OnSaveOutfitPopupClosed(data: ref<inkGameNotificationData>) {
        let resultData = data as GenericMessageNotificationCloseData;

        if Equals(resultData.result, GenericMessageNotificationResult.Confirm) && NotEquals(resultData.input, "") {
            let outfitName = StringToName(resultData.input);

            if this.m_outfitSystem.HasOutfit(outfitName) {
                this.ShowReplaceOutfitPopup(outfitName);
                return;
            }
            
            this.PlaySound(n"Item", n"OnBuy");
            
            if this.m_outfitSystem.SaveOutfit(outfitName, true) {
                this.AppendToList(outfitName, true);
            }
        }

        this.ResetPopupState();
    }

    protected cb func ShowReplaceOutfitPopup(outfitName: CName) {
        this.m_popupOutfit = outfitName;
        this.m_popupToken = GenericMessageNotification.Show(this.m_wardrobeScreen, GetLocalizedTextByKey(n"UI-Wardrobe-SaveSet"), GetLocalizedTextByKey(n"UI-Wardrobe-NotificationReplaceSet"), GenericMessageNotificationType.ConfirmCancel);
        this.m_popupToken.RegisterListener(this, n"OnReplaceOutfitPopupClosed");
    }

    protected cb func OnReplaceOutfitPopupClosed(data: ref<inkGameNotificationData>) {
        let resultData = data as GenericMessageNotificationCloseData;

        if Equals(resultData.result, GenericMessageNotificationResult.Confirm) {
            this.PlaySound(n"Item", n"OnBuy");

            if this.m_outfitSystem.SaveOutfit(this.m_popupOutfit, true) {
                this.RefreshList(true);
            }
        }

        this.ResetPopupState();
    }

    protected cb func ShowDeleteOutfitPopup(outfitName: CName) {
        this.m_popupOutfit = outfitName;
        this.m_popupToken = GenericMessageNotification.Show(this.m_wardrobeScreen, GetLocalizedTextByKey(n"UI-Wardrobe-Deleteset"), GetLocalizedTextByKey(n"UI-Wardrobe-NotificationDeleteSet"), GenericMessageNotificationType.ConfirmCancel);
        this.m_popupToken.RegisterListener(this, n"OnDeleteOutfitPopupClosed");
    }

    protected cb func OnDeleteOutfitPopupClosed(data: ref<inkGameNotificationData>) {
        let resultData = data as GenericMessageNotificationCloseData;

        if Equals(resultData.result, GenericMessageNotificationResult.Confirm) {
            this.PlaySound(n"Item", n"OnDisassemble");

            if this.m_outfitSystem.DeleteOutfit(this.m_popupOutfit) {
                this.RemoveFromList(this.m_popupOutfit, true);
            }
        }

        this.ResetPopupState();
    }

    protected func ResetPopupState() {
        this.m_popupOutfit = n"";
        this.m_popupToken = null;
    }

    protected func ShowButtonHints(entry: wref<OutfitListEntryData>) {
        this.m_buttonHints.RemoveButtonHint(n"click");
        this.m_buttonHints.RemoveButtonHint(n"drop_item");
        
        if IsDefined(entry) {
            if entry.IsRemovable {
                this.m_buttonHints.AddButtonHint(n"drop_item", GetLocalizedTextByKey(n"UI-Wardrobe-Deleteset"));
            }

            if entry.IsSelectable && !entry.IsSelected {
                this.m_buttonHints.AddButtonHint(n"click", GetLocalizedTextByKey(n"Gameplay-Devices-Interactions-Equip"));
            }
        }
    }

    protected cb func OnOutfitUpdated(evt: ref<OutfitUpdated>) {
        this.RefreshList(true);
    }

    protected cb func OnOutfitPartUpdated(evt: ref<OutfitPartUpdated>) {
        this.RefreshList(true);
    }

    protected cb func OnOutfitListUpdated(evt: ref<OutfitListUpdated>) {
        this.PopulateList();
    }

    protected cb func OnScrollChanged(value: Vector2) {
        this.RefreshList();
    }

    protected func AccessOutfitSystem() -> Bool {
        if this.m_outfitSystem.IsBlocked() {
            let notification = new UIMenuNotificationEvent();
            notification.m_notificationType = UIMenuNotificationType.InventoryActionBlocked;           
            this.QueueEvent(notification);

            return false;
        }

        return true;
    }
}

public class OutfitMappingPopup extends InMenuPopup {
    private let m_itemID: ItemID;
    private let m_slotID: TweakDBID;
    private let m_system: ref<OutfitSystem>;
    private let m_options: array<wref<OutfitSlotOptionController>>;
    private let m_arranged: Bool;

    protected cb func OnCreate() {
        super.OnCreate();

        let content = InMenuPopupContent.Create();
        content.SetTitle(this.m_system.GetItemName(this.m_itemID));
        content.Reparent(this);

        let panel = new inkHorizontalPanel();
        panel.SetMargin(inkMargin(0, 24, 0, 0));
        panel.Reparent(content.GetContainerWidget());

        let outfitSlots = OutfitConfig.OutfitSlots();

        let schema = [
            [n"Head", n"Face", n"Ears", n"Neck"],
            [n"Torso", n"Back",  n"Waist", n"Body"],
            [n"Arms", n"Hands", n"Fingers"],
            [n"Legs", n"Feet", n"Toes"]
        ];

        for areas in schema {
            let column = new inkVerticalPanel();
            column.Reparent(panel);

            for area in areas {
                for outfitSlot in outfitSlots {
                    if Equals(outfitSlot.slotArea, area) {
                        let option = this.SpawnOption(column);
                        option.SetData(outfitSlot, Equals(this.m_slotID, outfitSlot.slotID));

                        ArrayPush(this.m_options, option);
                    }
                }

                if NotEquals(area, ArrayLast(areas)) {
                    let divider = new inkCanvas();
                    divider.SetMargin(0, 0, 0, 40);
                    divider.Reparent(column);
                }
            }
        }

        let footer = InMenuPopupFooter.Create();
        footer.Reparent(this);

        let confirmBtn = PopupButton.Create();
        confirmBtn.SetText(GetLocalizedTextByKey(n"UI-UserActions-Equip")); // GetLocalizedText("LocKey#23123")
        confirmBtn.SetInputAction(n"one_click_confirm");
        confirmBtn.Reparent(footer);

        let cancelBtn = PopupButton.Create();
        cancelBtn.SetText(GetLocalizedText("LocKey#22175"));
        cancelBtn.SetInputAction(n"cancel");
        cancelBtn.Reparent(footer);
    }

    protected func SpawnOption(parent: ref<inkCompoundWidget>) -> ref<OutfitSlotOptionController> {
        let widget = this.SpawnFromExternal(parent, r"equipment_ex\\gui\\wardrobe.inkwidget",
            n"OutfitListEntry:EquipmentEx.OutfitSlotOptionController");
        return widget.GetController() as OutfitSlotOptionController;
    }

    protected cb func OnArrangeChildrenComplete() {
        if !this.m_arranged {
            for option in this.m_options {
                option.UpdateView();
            }

            this.m_arranged = true;
        }
    }

    protected cb func OnChange(evt: ref<OutfitSlotOptionChange>) {
        this.m_slotID = evt.slotID;
    }

    protected cb func OnConfirm() {
        this.m_system.AssignItem(this.m_itemID, this.m_slotID);

        if !this.m_system.IsEquipped(this.m_itemID) {
            this.m_system.EquipItem(this.m_itemID);
        }
    }

    public static func Show(requester: ref<inkGameController>, itemID: ItemID, system: ref<OutfitSystem>) {
        let popup = new OutfitMappingPopup();
        popup.m_itemID = itemID;
        popup.m_slotID = system.GetItemSlot(itemID);
        popup.m_system = system;
        popup.Open(requester);
    }

    func OnCancel() {}
    func OnShown() {}
    func OnReparent(parent: ref<inkCompoundWidget>) {}
}

class OutfitSlotOptionChange extends Event {
    public let slotID: TweakDBID;
}

class OutfitSlotOptionController extends inkButtonController {
    private let m_data: ExtraSlotConfig;

    private let m_root: wref<inkCompoundWidget>;
    private let m_label: wref<inkText>;
    private let m_checkbox: wref<inkWidget>;
    private let m_selection: wref<inkWidget>;

    private let m_disabled: Bool;
    private let m_hovered: Bool;
    private let m_selected: Bool;

    protected cb func OnInitialize() {
        this.m_root = this.GetRootCompoundWidget();

        this.m_label = this.GetChildWidgetByPath(n"titleAndCheckbox/FilterName") as inkText;
        this.m_label.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        
        this.m_checkbox = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox");
        this.m_selection = this.GetChildWidgetByPath(n"titleAndCheckbox/checkbox/checkbox");

        this.RegisterToCallback(n"OnRelease", this, n"OnRelease");
        this.RegisterToCallback(n"OnEnter", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnLeave", this, n"OnHoverOut");       
    }

    protected cb func OnRelease(evt: ref<inkPointerEvent>) {
        if evt.IsAction(n"click") && !this.m_disabled && !this.m_selected {
            this.TriggerChangeEvent();
        }
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        if !this.m_disabled {
            this.m_hovered = true;

            this.UpdateState();
        }
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        if !this.m_disabled {
            this.m_hovered = false;    
                   
            this.UpdateState();
        }
    }

    protected cb func OnOptionChange(evt: ref<OutfitSlotOptionChange>) {
        this.m_selected = Equals(this.m_data.slotID, evt.slotID);
        this.UpdateState();
    }

    protected func UpdateView() {
        this.m_root.SetSize(Vector2(this.m_label.GetDesiredWidth() + 170.0, 80.0));

        this.m_label.SetText(GetLocalizedText(this.m_data.displayName));
        this.m_label.BindProperty(n"fontStyle", n"MainColors.BodyFontWeight");
        this.m_label.BindProperty(n"fontSize", n"MainColors.ReadableSmall");

        this.m_checkbox.SetVisible(true);
        this.m_label.SetMargin(inkMargin(20, 0, 0, 0));

        this.GetChildWidgetByPath(n"titleAndCheckbox").SetMargin(inkMargin(0, 0, 0, 0));
        this.GetChildWidgetByPath(n"background").SetVisible(false);
    }

    protected func UpdateState() {
        this.m_selection.SetVisible(this.m_selected);

        if this.m_disabled {
            this.m_root.SetState(n"Default");
            this.m_root.SetOpacity(0.3);
        } else {
            this.m_root.SetOpacity(1.0);

            if this.m_hovered {
                this.m_root.SetState(n"Hover");
            }
            else {
                if this.m_selected {
                    this.m_root.SetState(n"Selected");
                }
                else {
                    this.m_root.SetState(n"Default");
                }
            }

            this.m_label.BindProperty(n"tintColor", this.m_selected ? n"MainColors.Blue" : n"MainColors.Red");
        }
    }

    protected func TriggerChangeEvent() {
        let evt = new OutfitSlotOptionChange();
        evt.slotID = this.m_data.slotID;

        this.QueueEvent(evt);
    }

    public func SetData(data: ExtraSlotConfig, selected: Bool) {
        this.m_data = data;
        this.m_selected = selected;

        this.UpdateView();
        this.UpdateState();
    }

    public func GetSlotID() -> TweakDBID {
        return this.m_data.slotID;
    }

    public func IsSelected() -> Bool {
        return this.m_selected;
    }
}

public class RequirementsPopup {
    public static func Show(controller: ref<worlduiIGameController>) -> ref<inkGameNotificationToken> {
        let params = new inkTextParams();

        params.AddString("archive_xl_req", CompatibilityManager.RequiredArchiveXL());
        params.AddString("tweak_xl_req", CompatibilityManager.RequiredTweakXL());
        params.AddString("codeware_req", CompatibilityManager.RequiredCodeware());

        params.AddString("archive_xl_ver", ArchiveXL.Version());
        params.AddString("tweak_xl_ver", TweakXL.Version());
        params.AddString("codeware_ver", Codeware.Version());

        return GenericMessageNotification.Show(
            controller, 
            GetLocalizedText("LocKey#11447"), 
            GetLocalizedTextByKey(n"UI-EquipmentEx-NotificationRequirements"), 
            params,
            GenericMessageNotificationType.OK
        );
    }
}

class SettingsButtonClick extends Event {
    public let action: ref<inkActionName>;
}

class SettingsButton extends inkCustomController {
    protected let m_frame: wref<inkImage>;
    protected let m_icon: wref<inkCompoundWidget>;

    protected cb func OnCreate() {
        let root = new inkCanvas();
        root.SetSize(110.0, 80.0);
        root.SetAnchorPoint(Vector2(0.5, 0.5));
        root.SetInteractive(true);

        let frame = new inkImage();
        frame.SetName(n"frame");
        frame.SetAnchor(inkEAnchor.Fill);
        frame.SetNineSliceScale(true);
        frame.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        frame.SetTexturePart(n"status_cell_fg");
        frame.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
        frame.BindProperty(n"tintColor", n"FilterButton.frameColor");
        frame.BindProperty(n"opacity", n"FilterButton.frameOpacity");
        frame.Reparent(root);

        let icon = new inkVerticalPanel();
        icon.SetAnchor(inkEAnchor.Centered);
        icon.SetAnchorPoint(Vector2(0.5, 0.5));
        icon.SetChildMargin(inkMargin(0.0, 4.0, 0.0, 4.0));
        icon.Reparent(root);

        let i = 0;
        while i < 3 {
            let line = new inkRectangle();
            line.SetHAlign(inkEHorizontalAlign.Center);
            line.SetSize(Vector2(33.0, 2.0));
            line.SetStyle(r"base\\gameplay\\gui\\common\\components\\toggles_style.inkstyle");
            line.BindProperty(n"tintColor", n"FilterButton.iconColor");
            line.Reparent(icon);

            i += 1;
        }

        this.m_frame = frame;
        this.m_icon = icon;

        this.SetRootWidget(root);
    }

    protected cb func OnInitialize() {
        this.RegisterToCallback(n"OnClick", this, n"OnClick");
        this.RegisterToCallback(n"OnHoverOver", this, n"OnHoverOver");
        this.RegisterToCallback(n"OnHoverOut", this, n"OnHoverOut");
    }

    protected cb func OnClick(evt: ref<inkPointerEvent>) {
        this.TriggerClickEvent(evt.GetActionName());
    }

    protected cb func OnHoverOver(evt: ref<inkPointerEvent>) {
        this.GetRootWidget().SetState(n"Hover");
    }

    protected cb func OnHoverOut(evt: ref<inkPointerEvent>) {
        this.GetRootWidget().SetState(n"Default");
    }

    protected func TriggerClickEvent(action: ref<inkActionName>) {
        let evt = new SettingsButtonClick();
        evt.action = action;

        let uiSystem = GameInstance.GetUISystem(this.GetGame());
        uiSystem.QueueEvent(evt);
    }

    public static func Create() -> ref<SettingsButton> {
        let self = new SettingsButton();
        self.CreateInstance();

        return self;
    }

    func OnReparent(parent: ref<inkCompoundWidget>) {}
}

public class ViewSettingsPopup extends InMenuPopup {
    private let m_itemSource: WardrobeItemSource;
    private let m_viewManager: ref<ViewManager>;
    private let m_options: array<wref<ItemSourceOptionController>>;
    private let m_arranged: Bool;

    protected cb func OnCreate() {
        super.OnCreate();

        this.m_viewManager = ViewManager.GetInstance(this.GetGame());
        this.m_itemSource = this.m_viewManager.GetItemSource();

        let content = InMenuPopupContent.Create();
        content.SetTitle(GetLocalizedTextByKey(n"UI-EquipmentEx-WardrobeItemSource"));
        content.Reparent(this);

        let panel = new inkVerticalPanel();
        panel.SetMargin(inkMargin(0, 24, 0, 0));
        panel.Reparent(content.GetContainerWidget());

        for itemSource in [WardrobeItemSource.WardrobeStore, WardrobeItemSource.InventoryAndStash, WardrobeItemSource.InventoryOnly] {
            let option = this.SpawnOption(panel);
            option.SetData(itemSource, Equals(this.m_itemSource, itemSource));
            ArrayPush(this.m_options, option);
        }

        let footer = InMenuPopupFooter.Create();
        footer.Reparent(this);

        let confirmBtn = PopupButton.Create();
        confirmBtn.SetText(GetLocalizedTextByKey(n"UI-ResourceExports-Confirm"));
        confirmBtn.SetInputAction(n"one_click_confirm");
        confirmBtn.Reparent(footer);

        let cancelBtn = PopupButton.Create();
        cancelBtn.SetText(GetLocalizedText("LocKey#22175"));
        cancelBtn.SetInputAction(n"cancel");
        cancelBtn.Reparent(footer);
    }

    protected func SpawnOption(parent: ref<inkCompoundWidget>) -> ref<ItemSourceOptionController> {
        let widget = this.SpawnFromExternal(parent, r"equipment_ex\\gui\\wardrobe.inkwidget",
            n"OutfitListEntry:EquipmentEx.ItemSourceOptionController");
        return widget.GetController() as ItemSourceOptionController;
    }

    protected cb func OnArrangeChildrenComplete() {
        if !this.m_arranged {
            for option in this.m_options {
                option.UpdateView();
            }

            this.m_arranged = true;
        }
    }

    protected cb func OnChange(evt: ref<ItemSourceOptionChange>) {
        this.m_itemSource = evt.value;
    }

    protected cb func OnConfirm() {
        this.m_viewManager.SetItemSource(this.m_itemSource);
    }

    public static func Show(requester: ref<inkGameController>) {
        let popup = new ViewSettingsPopup();
        popup.Open(requester);
    }

    func OnCancel() {}
    func OnShown() {}
    func OnReparent(parent: ref<inkCompoundWidget>) {}
}

public class WardrobeHubBtnController extends WardrobeOutfitSlotController {
    protected cb func OnInitialize() -> Bool {
        super.OnInitialize();

        this.Setup(0, true, false, false);
        this.GetRootWidget().SetWidth(600);

        inkTextRef.SetText(this.m_slotNumberText, GetLocalizedTextByKey(n"UI-Wardrobe-Tooltip-OutfitInfoTitle"));
    }
}

public class WardrobeHubLinkController extends MenuItemController {
    protected cb func OnInitialize() -> Bool {
        super.OnInitialize();

        let data: MenuData;
        data.label = GetLocalizedTextByKey(n"UI-Wardrobe-Tooltip-OutfitInfoTitle");
        data.icon = n"ico_wardrobe";
        data.fullscreenName = n"inventory_screen";
        data.identifier = EnumInt(HubMenuItems.Inventory);
        data.parentIdentifier = EnumInt(HubMenuItems.None);

        this.Init(data);
    }
}

public class WardrobeScreenController extends inkPuppetPreviewGameController {
    protected let m_player: wref<PlayerPuppet>;
    protected let m_outfitSystem: wref<OutfitSystem>;
    protected let m_viewManager: wref<ViewManager>;
    protected let m_inventoryHelper: wref<InventoryHelper>;
    protected let m_paperdollHelper: wref<PaperdollHelper>;
    protected let m_delaySystem: wref<DelaySystem>;
    protected let m_uiScriptableSystem: wref<UIScriptableSystem>;
    protected let m_uiInventorySystem: wref<UIInventoryScriptableSystem>;

    protected let m_outfitManager: wref<OutfitManagerController>;
    protected let m_buttonHints: wref<ButtonHints>;
    protected let m_tooltipManager: wref<gameuiTooltipsManager>;

    protected let m_filtersContainer: ref<inkUniformGrid>;
    protected let m_filtersRadioGroup: ref<FilterRadioGroup>;
    protected let m_filterManager: ref<ItemCategoryFliterManager>;
    protected let m_itemDropQueue: array<ItemModParams>;

    protected let m_inventoryScrollArea: wref<inkCompoundWidget>;
    protected let m_inventoryScrollController: wref<inkScrollController>;
    protected let m_scrollResetPending: Bool;
    protected let m_scrollLastPosition: Float;
    protected let m_scrollLastDelta: Float;

    protected let m_inventoryGridArea: wref<inkWidget>;
    protected let m_inventoryGridController: wref<inkVirtualGridController>;
    protected let m_inventoryGridDataView: ref<InventoryGridDataView>;
    protected let m_inventoryGridDataSource: ref<ScriptableDataSource>;
    protected let m_inventoryGridTemplateClassifier: ref<inkVirtualItemTemplateClassifier>;
    protected let m_inventoryGridUpdateDelay: Float = 0.5;
    protected let m_inventoryGridUpdateDelayID: DelayID;

    protected let m_searchInput: ref<HubTextInput>;

    protected let m_inventoryBlackboard: wref<IBlackboard>;
    protected let m_itemAddedCallback: ref<CallbackHandle>;
    protected let m_itemRemovedCallback: ref<CallbackHandle>;

    protected let m_equipmentBlackboard: wref<IBlackboard>;
    protected let m_equipProgressCallback: ref<CallbackHandle>;

    protected let m_previewWrapper: wref<inkWidget>;

    protected let m_isPreviewMouseHold: Bool;
    protected let m_isCursorOverManager: Bool;
    protected let m_isCursorOverPreview: Bool;

    protected let m_cursorScreenPosition: Vector2;

    protected let m_itemDisplayContext: ref<ItemDisplayContextData>;
    protected let m_isEquipInProgress: Bool;

    protected cb func OnInitialize() -> Bool {
        super.OnInitialize();

        this.m_player = this.GetPlayerControlledObject() as PlayerPuppet;
        this.m_outfitSystem = OutfitSystem.GetInstance(this.m_player.GetGame());
        this.m_viewManager = ViewManager.GetInstance(this.m_player.GetGame());
        this.m_inventoryHelper = InventoryHelper.GetInstance(this.m_player.GetGame());
        this.m_paperdollHelper = PaperdollHelper.GetInstance(this.m_player.GetGame());
        this.m_delaySystem = GameInstance.GetDelaySystem(this.m_player.GetGame());
        this.m_uiScriptableSystem = UIScriptableSystem.GetInstance(this.m_player.GetGame());
        this.m_uiInventorySystem = UIInventoryScriptableSystem.GetInstance(this.m_player.GetGame());

        this.m_buttonHints = this.SpawnFromExternal(this.GetChildWidgetByPath(n"button_hints"), r"base\\gameplay\\gui\\common\\buttonhints.inkwidget", n"Root").GetController() as ButtonHints;
        this.m_buttonHints.AddButtonHint(n"back", GetLocalizedTextByKey(n"Common-Access-Close"));

        this.m_outfitManager = this.SpawnFromLocal(this.GetChildWidgetByPath(n"wrapper/wrapper"), n"OutfitManager:EquipmentEx.OutfitManagerController").GetController() as OutfitManagerController;
        this.m_outfitManager.Setup(this.m_outfitSystem, this, this.m_buttonHints);

        this.m_inventoryScrollArea = this.GetChildWidgetByPath(n"wrapper/wrapper/vendorPanel/inventoryContainer") as inkCompoundWidget;
        this.m_inventoryScrollController = this.m_inventoryScrollArea.GetController() as inkScrollController;

        this.m_inventoryGridArea = this.m_inventoryScrollArea.GetWidget(n"stash_scroll_area_cache/scrollArea/vendor_virtualgrid");
        this.m_inventoryGridController = this.m_inventoryGridArea.GetController() as inkVirtualGridController;

        this.m_isCursorOverManager = false;
        this.m_isCursorOverPreview = false;

        this.m_tooltipManager = this.GetRootWidget().GetControllerByType(n"gameuiTooltipsManager") as gameuiTooltipsManager;
        this.m_tooltipManager.Setup(ETooltipsStyle.Menus);

        this.m_inventoryBlackboard = GameInstance.GetBlackboardSystem(this.m_player.GetGame()).Get(GetAllBlackboardDefs().UI_Inventory);
        this.m_itemAddedCallback = this.m_inventoryBlackboard.RegisterListenerVariant(GetAllBlackboardDefs().UI_Inventory.itemAdded, this, n"OnInventoryItemsChanged");
        this.m_itemRemovedCallback = this.m_inventoryBlackboard.RegisterListenerVariant(GetAllBlackboardDefs().UI_Inventory.itemRemoved, this, n"OnInventoryItemsChanged");

        this.m_equipmentBlackboard = GameInstance.GetBlackboardSystem(this.m_player.GetGame()).Get(GetAllBlackboardDefs().UI_Equipment);
        this.m_equipProgressCallback = this.m_equipmentBlackboard.RegisterListenerBool(GetAllBlackboardDefs().UI_Equipment.EquipmentInProgress, this, n"OnEquipmentProgress");


        this.m_filtersContainer = this.GetChildWidgetByPath(n"wrapper/wrapper/vendorPanel/vendorHeader/inkHorizontalPanelWidget2/filtersContainer") as inkUniformGrid;
        this.m_filtersContainer.SetWrappingWidgetCount(2u);

        this.m_filterManager = ItemCategoryFliterManager.Make();
        this.m_filterManager.Clear();
        this.m_filterManager.AddFilter(ItemFilterCategory.AllItems);
        this.m_filterManager.AddFilter(ItemFilterCategory.Clothes); // Equipped

        this.m_filtersRadioGroup = this.m_filtersContainer.GetController() as FilterRadioGroup;
        this.m_filtersRadioGroup.SetData(this.m_filterManager.GetIntFiltersList());
        this.m_filtersRadioGroup.RegisterToCallback(n"OnValueChanged", this, n"OnFilterChange");
        this.m_filtersRadioGroup.Toggle(EnumInt(ItemFilterCategory.AllItems));


        this.m_previewWrapper = this.GetChildWidgetByPath(n"wrapper/preview");


        this.m_itemDisplayContext = ItemDisplayContextData.Make(this.m_player, ItemDisplayContext.GearPanel);


        this.m_outfitManager.RegisterToCallback(n"OnEnter", this, n"OnManagerHoverOver");
        this.m_outfitManager.RegisterToCallback(n"OnLeave", this, n"OnManagerHoverOut");
        
        this.m_previewWrapper.RegisterToCallback(n"OnPress", this, n"OnPreviewPress");
        this.m_previewWrapper.RegisterToCallback(n"OnAxis", this, n"OnPreviewAxis");
        this.m_previewWrapper.RegisterToCallback(n"OnRelative", this, n"OnPreviewRelative");
        this.m_previewWrapper.RegisterToCallback(n"OnEnter", this, n"OnPreviewHoverOver");
        this.m_previewWrapper.RegisterToCallback(n"OnLeave", this, n"OnPreviewHoverOut");

        this.RegisterToGlobalInputCallback(n"OnPostOnPress", this, n"OnGlobalPress");
        this.RegisterToGlobalInputCallback(n"OnPostOnRelease", this, n"OnGlobalRelease");
        this.RegisterToGlobalInputCallback(n"OnPostOnHold", this, n"OnGlobalHold");
        this.RegisterToGlobalInputCallback(n"OnPreOnRelative", this, n"OnGlobalRelative");
        this.RegisterToGlobalInputCallback(n"OnPreOnAxis", this, n"OnGlobalAxis");

        this.InitializeInventoryGrid();
        this.InitializeSearchField();
        this.InitializeGridButtons();
    }

    protected cb func OnUninitialize() -> Bool {
        super.OnUninitialize();

        this.PlaySound(n"GameMenu", n"OnClose");

        this.m_delaySystem.CancelDelay(this.m_inventoryGridUpdateDelayID);

        this.m_uiInventorySystem.FlushFullscreenCache();

        this.m_inventoryGridDataView.SetSource(null);
        this.m_inventoryGridController.SetSource(null);
        this.m_inventoryGridController.SetClassifier(null);
        this.m_inventoryGridTemplateClassifier = null;
        this.m_inventoryGridDataView = null;
        this.m_inventoryGridDataSource = null;

        this.UnregisterFromGlobalInputCallback(n"OnPostOnPress", this, n"OnGlobalPress");
        this.UnregisterFromGlobalInputCallback(n"OnPostOnRelease", this, n"OnGlobalRelease");
        this.UnregisterFromGlobalInputCallback(n"OnPostOnHold", this, n"OnGlobalHold");
        this.UnregisterFromGlobalInputCallback(n"OnPostOnRelative", this, n"OnGlobalRelative");
        this.UnregisterFromGlobalInputCallback(n"OnPreOnAxis", this, n"OnGlobalAxis");

        this.m_inventoryBlackboard.UnregisterListenerVariant(GetAllBlackboardDefs().UI_Inventory.itemAdded, this.m_itemAddedCallback);
        this.m_inventoryBlackboard.UnregisterListenerVariant(GetAllBlackboardDefs().UI_Inventory.itemRemoved, this.m_itemRemovedCallback);
        this.m_equipmentBlackboard.UnregisterListenerBool(GetAllBlackboardDefs().UI_Equipment.EquipmentInProgress, this.m_equipProgressCallback);
    }

    protected func InitializeSearchField() {
        let filterWrapper = this.GetChildWidgetByPath(n"wrapper/wrapper/vendorPanel/vendorHeader/inkHorizontalPanelWidget2") as inkCompoundWidget;
        let filterSpacing = this.m_filtersContainer.GetChildMargin();

        let searchWrapper = new inkCanvas();
        searchWrapper.SetMargin(inkMargin(filterSpacing.right, 0, 0, filterSpacing.bottom));
        searchWrapper.Reparent(filterWrapper);

        this.m_searchInput = HubTextInput.Create();
        this.m_searchInput.SetName(n"SearchTextInput");
        this.m_searchInput.SetDefaultText(GetLocalizedTextByKey(n"UI-Wardrobe-SearchByName"));
        this.m_searchInput.SetLetterCase(textLetterCase.UpperCase);
        this.m_searchInput.SetMaxLength(24);
        this.m_searchInput.RegisterToCallback(n"OnInput", this, n"OnSearchFieldInput");
        this.m_searchInput.Reparent(searchWrapper);
    }

    protected func InitializeGridButtons() {
        let headerWrapper = this.GetChildWidgetByPath(n"wrapper/wrapper/vendorPanel/vendorHeader/vendoHeaderWrapper") as inkCompoundWidget;

        let buttonPanel = new inkHorizontalPanel();
        buttonPanel.SetAnchor(inkEAnchor.TopRight);
        buttonPanel.SetAnchorPoint(Vector2(1.0, 0.0));
        buttonPanel.SetMargin(inkMargin(0.0, 186.0, 0.0, 0.0));
        buttonPanel.SetChildMargin(inkMargin(8.0, 0.0, 0.0, 0.0));
        buttonPanel.Reparent(headerWrapper);

        let modeBtn = SettingsButton.Create();
        modeBtn.Reparent(buttonPanel, this);
        modeBtn.GetRootWidget().SetMargin(inkMargin(0, 0, 10, 0));

        let expandBtn = CollapseButton.Create();
        expandBtn.SetFlipped(true);
        expandBtn.Reparent(buttonPanel, this);

        let collapseBtn = CollapseButton.Create();
        collapseBtn.SetCollapse(true);
        collapseBtn.Reparent(buttonPanel, this);
    }

    protected func InitializeInventoryGrid() {
        this.m_inventoryGridDataSource = new ScriptableDataSource();
        
        this.m_inventoryGridDataView = new InventoryGridDataView();
        this.m_inventoryGridDataView.SetViewManager(this.m_viewManager);
        this.m_inventoryGridDataView.BindUIScriptableSystem(this.m_uiScriptableSystem);
        this.m_inventoryGridDataView.SetFilterType(ItemFilterCategory.AllItems);
        this.m_inventoryGridDataView.SetSortMode(ItemSortMode.Default);
        this.m_inventoryGridDataView.SetSource(this.m_inventoryGridDataSource);

        this.m_inventoryGridTemplateClassifier = new InventoryGridTemplateClassifier();
        
        this.m_inventoryGridController.SetClassifier(this.m_inventoryGridTemplateClassifier);
        this.m_inventoryGridController.SetSource(this.m_inventoryGridDataView);

        this.PopulateInventoryGrid();
    }

    protected func PopulateInventoryGrid() {
        let slotMap = new inkHashMap();
        for slotID in this.m_outfitSystem.GetOutfitSlots() {
            let uiSlotData = new InventoryGridSlotData();
            uiSlotData.ItemData.SlotID = slotID;
            uiSlotData.ItemData.CategoryName = this.m_outfitSystem.GetSlotName(slotID);

            slotMap.Insert(TDBID.ToNumber(slotID), uiSlotData);
        }

        for itemData in this.m_inventoryHelper.GetAvailableItems(this.m_itemDropQueue) {
            let slotIDs = [this.m_outfitSystem.GetItemSlot(itemData.ID)];
            for slotID in slotIDs {
                let uiSlotData = slotMap.Get(TDBID.ToNumber(slotID)) as InventoryGridSlotData;
                let uiItemData = new InventoryGridItemData();
                uiItemData.Item = UIInventoryItem.Make(this.m_player, slotID, itemData, this.m_uiInventorySystem.GetInventoryItemsManager());
                uiItemData.DisplayContextData = this.m_itemDisplayContext;
                uiItemData.Parent = uiSlotData;

                if uiItemData.Item.IsEquipped() {
                    uiSlotData.ItemData.ID = uiItemData.Item.GetID();
                    uiSlotData.ItemData.Name = uiItemData.Item.GetName();
                    uiSlotData.ItemData.IsEquipped = true;
                }

                let index = 0;
                while index < ArraySize(uiSlotData.Children) && !this.CompareItem(itemData.ID, uiSlotData.Children[index].Item.GetID()) {
                    index += 1;
                }
                ArrayInsert(uiSlotData.Children, index, uiItemData);
            }
        }

        let finalItems: array<ref<IScriptable>>;
        for slotID in this.m_outfitSystem.GetOutfitSlots() {
            let uiSlotData = slotMap.Get(TDBID.ToNumber(slotID)) as InventoryGridSlotData;
            if ArraySize(uiSlotData.Children) > 0 {
                ArrayPush(finalItems, uiSlotData);
                for uiItemData in uiSlotData.Children {
                    ArrayPush(finalItems, uiItemData);
                }
            }
        }

        this.m_inventoryGridDataSource.Reset(finalItems);
        this.m_inventoryGridDataView.UpdateView();
    }

    protected func CompareItem(leftItemID: ItemID, rightItemID: ItemID) -> Bool {
        let leftName = NameToString(TweakDBInterface.GetItemRecord(ItemID.GetTDBID(leftItemID)).AppearanceName());
        let rightName = NameToString(TweakDBInterface.GetItemRecord(ItemID.GetTDBID(rightItemID)).AppearanceName());

        if StrLen(leftName) == 0 {
            return false;
        }

        if StrLen(rightName) == 0 {
            return true;
        }

        return StrCmp(leftName, rightName) < 0;
    }

    protected func RefreshInventoryGrid() {
        this.m_inventoryGridDataView.UpdateView();
        this.m_inventoryScrollController.UpdateScrollPositionFromScrollArea();
    }

    protected func RestoreScrollPosition() {
        this.m_inventoryScrollController.SetScrollPosition(
            this.m_scrollLastPosition * this.m_scrollLastDelta / this.m_inventoryScrollController.scrollDelta
        );
    }

    protected cb func QueueScrollPositionRestore() {
        this.m_scrollLastPosition = this.m_inventoryScrollController.position;
        this.m_scrollLastDelta = this.m_inventoryScrollController.scrollDelta;

        this.m_delaySystem.DelayCallbackNextFrame(RestoreInventoryScrollCallback.Create(this));
    }

    protected func UpdateScrollPosition(opt forceReset: Bool) {
        if forceReset || this.m_scrollResetPending {
            this.m_inventoryScrollController.SetScrollPosition(0.0);
            this.m_scrollResetPending = false;
        }
    }

    protected cb func QueueInventoryGridUpdate(opt resetScroll: Bool) {
        if resetScroll {
            this.m_scrollResetPending = true;
        }

        this.m_delaySystem.CancelDelay(this.m_inventoryGridUpdateDelayID);
        this.m_inventoryGridUpdateDelayID = this.m_delaySystem.DelayCallback(UpdateInventoryGridCallback.Create(this), this.m_inventoryGridUpdateDelay, false);
    }

    protected cb func OnOutfitUpdated(evt: ref<OutfitUpdated>) {
        this.RefreshInventoryGrid();
    }

    protected cb func OnItemListUpdated(evt: ref<OutfitMappingUpdated>) {
        this.PopulateInventoryGrid();
        this.QueueScrollPositionRestore();
    }

    protected cb func OnItemSourceUpdated(evt: ref<ItemSourceUpdated>) {
        this.PopulateInventoryGrid();
        this.QueueScrollPositionRestore();
    }

    protected cb func OnDropQueueUpdated(evt: ref<DropQueueUpdatedEvent>) {
        this.m_itemDropQueue = evt.m_dropQueue;

        if IsDefined(this.m_inventoryGridDataSource) {
            this.PopulateInventoryGrid();
        }
    }

    protected cb func OnInventoryItemsChanged(value: Variant) {
        let data = FromVariant<ItemRemovedData>(value);
        if ItemID.IsValid(data.itemID) && this.m_outfitSystem.IsEquippable(data.itemID) {
            this.QueueInventoryGridUpdate();
        }
    }

    protected cb func OnEquipmentProgress(inProgress: Bool) {

    }

    protected cb func OnFilterChange(controller: wref<inkRadioGroupController>, selectedIndex: Int32) {
        this.UpdateScrollPosition(true);
        this.m_inventoryGridDataView.SetFilterType(this.m_filterManager.GetAt(selectedIndex));
        this.m_inventoryGridDataView.UpdateView();
    }

    protected cb func OnSearchFieldInput(widget: wref<inkWidget>) {
        this.UpdateScrollPosition(true);
        this.m_inventoryGridDataView.SetSearchQuery(this.m_searchInput.GetText());
        this.m_inventoryGridDataView.UpdateView();
    }

    protected final func ShowItemTooltip(widget: wref<inkWidget>, item: wref<UIInventoryItem>) {
        this.m_tooltipManager.HideTooltips();

        if IsDefined(item) {
            let data = UIInventoryItemTooltipWrapper.Make(item, this.m_itemDisplayContext);
            this.m_tooltipManager.ShowTooltipAtWidget(n"itemTooltip", widget, data, gameuiETooltipPlacement.RightTop);
        }
    }

    protected final func ShowItemButtonHints(item: wref<UIInventoryItem>) {
        this.m_buttonHints.RemoveButtonHint(n"equip_item");
        this.m_buttonHints.RemoveButtonHint(n"unequip_item");
        this.m_buttonHints.RemoveButtonHint(n"upgrade_perk");
        this.m_buttonHints.RemoveButtonHint(n"drop_item");
        
        let cursorContext = n"Default";
        let cursorData: ref<MenuCursorUserData>;

        if IsDefined(item) && ItemID.IsValid(item.ID) {
            cursorData = new MenuCursorUserData();
            cursorData.SetAnimationOverride(n"hoverOnHoldToComplete");
            cursorData.AddAction(n"upgrade_perk");
            cursorContext = n"HoldToComplete";

            if !item.IsEquipped() {
                this.m_buttonHints.AddButtonHint(n"drop_item", GetLocalizedTextByKey(n"UI-UserActions-Drop"));
            }

            this.m_buttonHints.AddButtonHint(n"upgrade_perk", 
                "[" + GetLocalizedText("Gameplay-Devices-Interactions-Helpers-Hold") + "] " 
                    + GetLocalizedTextByKey(n"UI-UserActions-Equip") + "...");

            if item.IsEquipped() {
                this.m_buttonHints.AddButtonHint(n"unequip_item", GetLocalizedTextByKey(n"UI-UserActions-Unequip"));
            } else {
                this.m_buttonHints.AddButtonHint(n"equip_item", GetLocalizedTextByKey(n"UI-UserActions-Equip"));
            }
        }

        this.SetCursorContext(cursorContext, cursorData);
    }

    protected cb func OnInventoryItemClick(evt: ref<ItemDisplayClickEvent>) {
        if this.m_isEquipInProgress {
            return;
        }

        if evt.actionName.IsAction(n"equip_item") {
            if !evt.uiInventoryItem.IsEquipped() && this.AccessOutfitSystem() {
                if this.m_outfitSystem.EquipItem(evt.uiInventoryItem.ID) {
                    this.ShowItemButtonHints(evt.uiInventoryItem);
                }
            }
            return;
        }
        
        if evt.actionName.IsAction(n"unequip_item") {
            if evt.uiInventoryItem.IsEquipped() && this.AccessOutfitSystem() {
                if this.m_outfitSystem.UnequipItem(evt.uiInventoryItem.ID) {
                    this.ShowItemButtonHints(evt.uiInventoryItem);
                }
            }
            return;
        }
        
        if evt.actionName.IsAction(n"drop_item") {
            if !evt.uiInventoryItem.IsEquipped() {
                this.m_inventoryHelper.DiscardItem(evt.uiInventoryItem.ID);
                this.PopulateInventoryGrid();
                this.QueueScrollPositionRestore();
            }
            return;
        }
    }

    protected cb func OnInventoryItemHold(evt: ref<ItemDisplayHoldEvent>) {
        if this.m_isEquipInProgress {
            return;
        }

        if evt.actionName.IsAction(n"upgrade_perk") {
            OutfitMappingPopup.Show(this, evt.uiInventoryItem.ID, this.m_outfitSystem);
        }
    }

    protected cb func OnInventoryItemHoverOver(evt: ref<ItemDisplayHoverOverEvent>) {
        this.ShowItemButtonHints(evt.uiInventoryItem);
        this.ShowItemTooltip(evt.widget, evt.uiInventoryItem);
    }

    protected cb func OnInventoryItemHoverOut(evt: ref<ItemDisplayHoverOutEvent>) {
        this.ShowItemButtonHints(null);
        this.m_tooltipManager.HideTooltips();
    }

    protected final func ShowSlotButtonHints(slot: wref<InventoryGridSlotData>) {
        this.m_buttonHints.RemoveButtonHint(n"click");
        
        if IsDefined(slot) {
            this.m_buttonHints.AddButtonHint(n"click", slot.IsCollapsed
                ? GetLocalizedTextByKey(n"Common-Access-Open")
                : GetLocalizedTextByKey(n"Common-Access-Close"));
        }
    }

    protected final func ShowGridButtonHints() {
        if this.m_player.PlayerLastUsedPad() && !this.m_isCursorOverManager && !this.m_isCursorOverPreview {
            this.m_buttonHints.AddButtonHint(n"world_map_menu_zoom_to_mappin", GetLocalizedText("LocKey#17809"));
        } else {
            this.m_buttonHints.RemoveButtonHint(n"world_map_menu_zoom_to_mappin");
        }
    }

    protected cb func OnInventoryGridSlotClick(evt: ref<InventoryGridSlotClick>) {
        if evt.action.IsAction(n"click") {
            this.PlaySound(n"Button", n"OnPress");

            this.m_inventoryGridDataView.ToggleCollapsed(evt.slot.ItemData.SlotID);
            this.m_inventoryGridDataView.UpdateView();
            this.QueueScrollPositionRestore();

            this.ShowSlotButtonHints(evt.slot);
        }
    }

    protected cb func OnInventoryGridSlotItemHoverOver(evt: ref<InventoryGridSlotHoverOver>) {
        this.ShowSlotButtonHints(evt.slot);
    }

    protected cb func OnInventoryGridSlotItemHoverOut(evt: ref<InventoryGridSlotHoverOut>) {
        this.ShowSlotButtonHints(null);
    }

    protected cb func OnInventoryGridCollapseClick(evt: ref<CollapseButtonClick>) {
        if evt.action.IsAction(n"click") {
            this.m_inventoryGridDataView.SetCollapsed(evt.collapse);
            this.m_inventoryGridDataView.UpdateView();
            this.QueueScrollPositionRestore();
        }
    }

    protected cb func OnInventoryGridSettingsClick(evt: ref<SettingsButtonClick>) {
        if evt.action.IsAction(n"click") {
            ViewSettingsPopup.Show(this);
        }
    }

    protected cb func OnManagerHoverOver(evt: ref<inkPointerEvent>) -> Bool {
        this.m_isCursorOverManager = true;
    }

    protected cb func OnManagerHoverOut(evt: ref<inkPointerEvent>) -> Bool {
        this.m_isCursorOverManager = false;
    }

    protected cb func OnPreviewHoverOver(evt: ref<inkPointerEvent>) -> Bool {
        this.m_buttonHints.AddButtonHint(n"drop_item", GetLocalizedTextByKey(n"UI-UserActions-Unequip") + " " + GetLocalizedTextByKey(n"UI-Filters-AllItems"));

        if this.m_player.PlayerLastUsedKBM() {
            this.m_buttonHints.AddButtonHint(n"mouse_wheel", GetLocalizedTextByKey(n"UI-ScriptExports-Zoom0"));
            this.m_buttonHints.AddButtonHint(n"mouse_left", GetLocalizedTextByKey(n"UI-ResourceExports-Rotate"));
        } else {
            this.m_buttonHints.AddButtonHint(n"right_stick_y", GetLocalizedTextByKey(n"UI-ScriptExports-Zoom0"));
            this.m_buttonHints.AddButtonHint(n"right_stick_x", GetLocalizedTextByKey(n"UI-ResourceExports-Rotate"));
        }

        this.m_isCursorOverPreview = true;
    }

    protected cb func OnPreviewHoverOut(evt: ref<inkPointerEvent>) -> Bool {
        this.m_buttonHints.RemoveButtonHint(n"drop_item");
        this.m_buttonHints.RemoveButtonHint(n"mouse_wheel");
        this.m_buttonHints.RemoveButtonHint(n"mouse_left");
        this.m_buttonHints.RemoveButtonHint(n"right_stick_y");
        this.m_buttonHints.RemoveButtonHint(n"right_stick_x");

        this.m_isCursorOverPreview = false;
    }

    protected cb func OnPreviewPress(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"click") {
            let cursorPos = evt.GetScreenSpacePosition();
            let screenSize = ScreenHelper.GetScreenSize(this.m_player.GetGame());

            this.m_cursorScreenPosition = Vector2(cursorPos.X / screenSize.X, cursorPos.Y / screenSize.Y);
        }

        if evt.IsAction(n"mouse_left") {
            this.m_isPreviewMouseHold = true;

            let cursorEvent = new inkMenuLayer_SetCursorVisibility();
            cursorEvent.Init(false);
            this.QueueEvent(cursorEvent);
        }
    }

    protected cb func OnPreviewAxis(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"right_stick_x") {
            this.RotatePreview(evt.GetAxisData(), 0.5);
        }

        if evt.IsAction(n"right_stick_y") && AbsF(evt.GetAxisData()) >= 0.85 {
            this.SetPreviewCamera(evt.GetAxisData() > 0.0);
        }
    }

    protected cb func OnPreviewRelative(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"mouse_wheel") && evt.GetAxisData() != 0.0 {
            this.SetPreviewCamera(evt.GetAxisData() > 0.0);
        }
    }

    protected cb func OnGlobalPress(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"mouse_left") {
            if !IsDefined(evt.GetTarget()) || !evt.GetTarget().CanSupportFocus() {
                this.RequestSetFocus(null);
            }
        }
    }

    protected cb func OnGlobalRelease(evt: ref<inkPointerEvent>) -> Bool {
        if this.m_isPreviewMouseHold && evt.IsAction(n"mouse_left") {
            this.m_isPreviewMouseHold = false;

            let cursorEvent = new inkMenuLayer_SetCursorVisibility();
            cursorEvent.Init(true, this.m_cursorScreenPosition);
            this.QueueEvent(cursorEvent);

            evt.Consume();
        }

        if !this.m_isCursorOverManager && !this.m_isCursorOverPreview 
            && this.m_player.PlayerLastUsedPad() && evt.IsAction(n"world_map_menu_zoom_to_mappin") {
            this.m_inventoryGridDataView.ToggleCollapsed();
            this.m_inventoryGridDataView.UpdateView();
            this.QueueScrollPositionRestore();
        }

        if this.m_isCursorOverPreview && evt.IsAction(n"drop_item") && this.AccessOutfitSystem() {
            this.m_outfitSystem.UnequipAll();
        }
    }

    protected cb func OnGlobalHold(evt: ref<inkPointerEvent>) -> Bool {
    }

    protected cb func OnGlobalAxis(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"right_stick_x") || evt.IsAction(n"right_stick_y") {
            this.m_inventoryScrollController.SetScrollEnabled(!this.m_isCursorOverManager && !this.m_isCursorOverPreview);
        }

        this.ShowGridButtonHints();
    }

    protected cb func OnGlobalRelative(evt: ref<inkPointerEvent>) -> Bool {
        if evt.IsAction(n"mouse_wheel") {
            this.m_inventoryScrollController.SetScrollEnabled(!this.m_isCursorOverManager && !this.m_isCursorOverPreview);
        }

        if this.m_isPreviewMouseHold && evt.IsAction(n"mouse_x") {
            this.RotatePreview(evt.GetAxisData(), 1.0, true);
        }

        if evt.IsAction(n"mouse_x") || evt.IsAction(n"mouse_y") {
            this.ShowGridButtonHints();
        }
    }

    protected func RotatePreview(offset: Float, speed: Float, opt clamp: Bool) {
        let puppet = this.m_paperdollHelper.GetPreview();

        if clamp {
            if offset > 0.00 {
                offset = ClampF(offset / puppet.m_maxMousePointerOffset, 0.50, 1.00);
            } else {
                offset = ClampF(offset / puppet.m_maxMousePointerOffset, -1.00, -0.50);
            }
        }

        puppet.Rotate(offset * speed * puppet.m_mouseRotationSpeed);
    }

    protected func SetPreviewCamera(zoomIn: Bool) {
        let puppet = this.m_paperdollHelper.GetPreview();
        let zoomArea = zoomIn ? InventoryPaperdollZoomArea.Head : InventoryPaperdollZoomArea.Default;

        let setCameraSetupEvent = new gameuiPuppetPreview_SetCameraSetupEvent();
        setCameraSetupEvent.setupIndex = Cast<Uint32>(EnumInt(zoomArea));

        puppet.QueueEvent(setCameraSetupEvent);
    }

    protected func AccessOutfitSystem() -> Bool {
        if this.m_outfitSystem.IsBlocked() {
            let notification = new UIMenuNotificationEvent();
            notification.m_notificationType = UIMenuNotificationType.InventoryActionBlocked;           
            this.QueueEvent(notification);

            return false;
        }

        return true;
    }
}

class UpdateInventoryGridCallback extends DelayCallback {
    protected let m_controller: wref<WardrobeScreenController>;

    public func Call() {
        if IsDefined(this.m_controller) {
            EquipmentSystem.GetData(this.m_controller.m_player).GetInventoryManager().MarkToRebuild();

            this.m_controller.UpdateScrollPosition();
            this.m_controller.PopulateInventoryGrid();
        }
    }

    public static func Create(controller: ref<WardrobeScreenController>) -> ref<UpdateInventoryGridCallback> {
        let self = new UpdateInventoryGridCallback();
        self.m_controller = controller;
        return self;
    }
}

class RestoreInventoryScrollCallback extends DelayCallback {
    protected let m_controller: wref<WardrobeScreenController>;

    public func Call() {
        if IsDefined(this.m_controller) {
            this.m_controller.RestoreScrollPosition();
        }
    }

    public static func Create(controller: ref<WardrobeScreenController>) -> ref<RestoreInventoryScrollCallback> {
        let self = new RestoreInventoryScrollCallback();
        self.m_controller = controller;
        return self;
    }
}
