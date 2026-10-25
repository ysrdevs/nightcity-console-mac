// EquipmentEx 1.2.9
import EquipmentEx.OutfitSystem
import EquipmentEx.InventoryHelper
import EquipmentEx.{CompatibilityManager, OutfitSystem, ArchivePopup, RequirementsPopup}
import EquipmentEx.PaperdollHelper
import EquipmentEx.{OutfitSystem,PaperdollHelper}
import EquipmentEx.{CompatibilityManager, ConflictsPopup, RequirementsPopup}

public abstract class EquipmentEx {
    public static func Version() -> String = "1.2.9";

    public static func Activate(game: GameInstance) {
        OutfitSystem.GetInstance(game).Activate();
    }
    
    public static func Reactivate(game: GameInstance) {
        OutfitSystem.GetInstance(game).Reactivate();
    }
    
    public static func Deactivate(game: GameInstance) {
        OutfitSystem.GetInstance(game).Deactivate();
    }
    
    public static func EquipItem(game: GameInstance, itemID: TweakDBID) {
        OutfitSystem.GetInstance(game).EquipItem(itemID);
    }

    public static func EquipItem(game: GameInstance, itemID: TweakDBID, slotID: TweakDBID) {
        OutfitSystem.GetInstance(game).EquipItem(itemID, slotID);
    }

    public static func UnequipItem(game: GameInstance, itemID: TweakDBID) {
        OutfitSystem.GetInstance(game).UnequipItem(itemID);
    }

    public static func UnequipSlot(game: GameInstance, slotID: TweakDBID) {
        OutfitSystem.GetInstance(game).UnequipSlot(slotID);
    }

    public static func UnequipAll(game: GameInstance) {
        OutfitSystem.GetInstance(game).UnequipAll();
    }

    public static func PrintItems(game: GameInstance) {
        let outfitSystem = OutfitSystem.GetInstance(game);
        let usedSlots = outfitSystem.GetUsedSlots();

        if ArraySize(usedSlots) > 0 {
            let transactionSystem = GameInstance.GetTransactionSystem(game);
            let player = GetPlayer(game);

            Print("=== Equipped Items ===");
            
            for slotID in usedSlots {
                let itemID = transactionSystem.GetItemInSlot(player, slotID).GetItemID();
                Print(s"\(outfitSystem.GetSlotName(slotID)) : \(outfitSystem.GetItemName(itemID))");
            }
            
            Print("===");
        } else {
            Print("=== No Equipped Items ===");
        }
    }

    public static func ExportItems(game: GameInstance) {
        let outfitSystem = OutfitSystem.GetInstance(game);
        let usedSlots = outfitSystem.GetUsedSlots();

        if ArraySize(usedSlots) > 0 {
            let transactionSystem = GameInstance.GetTransactionSystem(game);
            let player = GetPlayer(game);
            let command = "";
            
            for slotID in usedSlots {
                let itemID = transactionSystem.GetItemInSlot(player, slotID).GetItemID();
                command += s"EquipmentEx.EquipItem(\"\(TDBID.ToStringDEBUG(ItemID.GetTDBID(itemID)))\") ";
            }
            
            Print(command);
        }
    }

    public static func LoadOutfit(game: GameInstance, name: CName) {
        OutfitSystem.GetInstance(game).LoadOutfit(name);
    }

    public static func SaveOutfit(game: GameInstance, name: String) {
        OutfitSystem.GetInstance(game).SaveOutfit(StringToName(name), true);
    }

    public static func CopyOutfit(game: GameInstance, name: String, from: CName) {
        OutfitSystem.GetInstance(game).CopyOutfit(StringToName(name), from);
    }

    public static func DeleteOutfit(game: GameInstance, name: CName) {
        OutfitSystem.GetInstance(game).DeleteOutfit(name);
    }

    public static func DeleteAllOutfits(game: GameInstance) {
        OutfitSystem.GetInstance(game).DeleteAllOutfits();
        Print("All outfits deleted");
    }

    public static func PrintOutfits(game: GameInstance) {
        let outfitSystem = OutfitSystem.GetInstance(game);
        let outfitNames = outfitSystem.GetOutfits();

        if ArraySize(outfitNames) > 0 {
            Print("=== Saved Outfits ===");

            for outfitName in outfitNames {
                Print(NameToString(outfitName));
            }

            Print("===");
        } else {
            Print("=== No Saved Outfits ===");
        }
    }
}

@addField(BackpackMainGameController)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(BackpackMainGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetPlayerControlledObject().GetGame());
}

@wrapMethod(BackpackMainGameController)
protected cb func OnItemDisplayClick(evt: ref<ItemDisplayClickEvent>) -> Bool {
    if this.m_outfitSystem.IsActive() && evt.actionName.IsAction(n"preview_item") {
        if evt.uiInventoryItem.IsClothing() {
            return false;
        }
    }

    return wrappedMethod(evt);
}

@wrapMethod(BackpackMainGameController)
private final func NewShowItemHints(itemData: wref<UIInventoryItem>) {
    wrappedMethod(itemData);

    if this.m_outfitSystem.IsActive() {
        if itemData.IsClothing() {
            this.m_buttonHintsController.RemoveButtonHint(n"preview_item");
        }
    }
}

@wrapMethod(CraftingGarmentItemPreviewGameController)
protected cb func OnCrafrtingPreview(evt: ref<CraftingItemPreviewEvent>) -> Bool {
    if this.m_outfitSystem.IsActive() {
        if ItemID.IsValid(this.m_previewedItem) {
            this.m_previewedItem = ItemID.None();
            this.m_outfitSystem.EquipPuppetOutfit(this.GetGamePuppet());
        }
        
        if evt.isGarment {
            this.m_previewedItem = evt.itemID;
            this.m_outfitSystem.EquipPuppetItem(this.GetGamePuppet(), this.m_previewedItem);
        }
    } else {
        wrappedMethod(evt);
    }
}

@addField(EquipmentSystemPlayerData)
private let m_visualChangesAllowed: Bool;

@addField(EquipmentSystemPlayerData)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(EquipmentSystemPlayerData)
public final func OnAttach() {
    wrappedMethod();
    
    this.m_outfitSystem = OutfitSystem.GetInstance(this.m_owner.GetGame());
}

@addMethod(EquipmentSystemPlayerData)
public func LockVisualChanges() {
    this.m_visualChangesAllowed = false;
}

@addMethod(EquipmentSystemPlayerData)
public func UnlockVisualChanges() {
    this.m_visualChangesAllowed = true;
}

@wrapMethod(EquipmentSystemPlayerData)
public final const func IsVisualSetActive() -> Bool {
    return wrappedMethod() || this.m_outfitSystem.IsActive();
}

@wrapMethod(EquipmentSystemPlayerData)
public final const func IsSlotOverriden(area: gamedataEquipmentArea) -> Bool {
    return wrappedMethod(area) || (this.m_outfitSystem.IsManagedArea(area) && this.m_outfitSystem.IsActive());
}

@wrapMethod(EquipmentSystemPlayerData)
private final const func ShouldUnderwearBeVisibleInSet() -> Bool {
    return !this.m_outfitSystem.IsActive() && !this.m_visualChangesAllowed && wrappedMethod();
}

@wrapMethod(EquipmentSystemPlayerData)
private final const func ShouldUnderwearTopBeVisibleInSet() -> Bool {
    return !this.m_outfitSystem.IsActive() && !this.m_visualChangesAllowed && wrappedMethod();
}

@wrapMethod(EquipmentSystemPlayerData)
public final func OnRestored() {
    this.m_outfitSystem = OutfitSystem.GetInstance(this.m_owner.GetGame());
    this.m_wardrobeSystem = GameInstance.GetWardrobeSystem(this.m_owner.GetGame());

    if NotEquals(this.m_wardrobeSystem.GetActiveClothingSetIndex(), gameWardrobeClothingSetIndex.INVALID) {
        this.m_wardrobeSystem.SetActiveClothingSetIndex(gameWardrobeClothingSetIndex.INVALID);
        this.m_lastActiveWardrobeSet = gameWardrobeClothingSetIndex.INVALID;
    }

    if !this.m_outfitSystem.IsActive() {
        let i = 0;
        while i <= ArraySize(this.m_clothingVisualsInfo) {
            this.m_clothingVisualsInfo[i].isHidden = false;
            this.m_clothingVisualsInfo[i].visualItem = ItemID.None();
            i += 1;
        }
    }

    wrappedMethod();
}

@replaceMethod(EquipmentSystemPlayerData)
public final func OnQuestDisableWardrobeSetRequest(request: ref<QuestDisableWardrobeSetRequest>) {
    if this.m_outfitSystem.IsActive() {
        this.m_outfitSystem.Deactivate();
        this.m_lastActiveWardrobeSet = gameWardrobeClothingSetIndex.Slot1;
    }

    if request.blockReequipping {
        this.m_outfitSystem.Disable();
    }
}

@replaceMethod(EquipmentSystemPlayerData)
public final func OnQuestRestoreWardrobeSetRequest(request: ref<QuestRestoreWardrobeSetRequest>) {
    this.m_outfitSystem.Enable();

    if NotEquals(this.m_lastActiveWardrobeSet, gameWardrobeClothingSetIndex.INVALID) {
        this.m_outfitSystem.Reactivate();
        this.m_lastActiveWardrobeSet = gameWardrobeClothingSetIndex.INVALID;
    }
}

@replaceMethod(EquipmentSystemPlayerData)
public final func OnQuestEnableWardrobeSetRequest(request: ref<QuestEnableWardrobeSetRequest>) {
    this.m_outfitSystem.Enable();
}

@replaceMethod(EquipmentSystemPlayerData)
public final func EquipWardrobeSet(setID: gameWardrobeClothingSetIndex) {}

@replaceMethod(EquipmentSystemPlayerData)
public final func UnequipWardrobeSet() {}

@replaceMethod(EquipmentSystemPlayerData)
public final func QuestHideSlot(area: gamedataEquipmentArea) {}

@replaceMethod(EquipmentSystemPlayerData)
public final func QuestRestoreSlot(area: gamedataEquipmentArea) {}

@wrapMethod(EquipmentSystemPlayerData)
private final func ClearItemAppearanceEvent(area: gamedataEquipmentArea) {
    if this.m_visualChangesAllowed || !this.m_outfitSystem.IsActive() {
        wrappedMethod(area);
    }
}

@wrapMethod(EquipmentSystemPlayerData)
private final func ResetItemAppearanceEvent(area: gamedataEquipmentArea) {
    if this.m_visualChangesAllowed || !this.m_outfitSystem.IsActive() {
        wrappedMethod(area);
    }
}

@wrapMethod(EquipmentSystemPlayerData)
private final func ResetItemAppearance(area: gamedataEquipmentArea, opt force: Bool) {
    wrappedMethod(area, force);

    if Equals(area, gamedataEquipmentArea.Feet) && !this.IsSlotHidden(area) && !this.IsSlotOverriden(area) {
        let itemID = this.GetActiveItem(area);
        if ItemID.IsValid(itemID) {
            let slotID = this.GetPlacementSlotByAreaType(area);
            let transactionSystem = GameInstance.GetTransactionSystem(this.m_owner.GetGame());
            transactionSystem.RemoveItemFromSlot(this.m_owner, slotID);
            GameInstance.GetDelaySystem(this.m_owner.GetGame()).DelayCallback(EquipmentSystemReattachItem.Create(this, slotID, itemID), 1.0 / 60.0, false);
        }
    }
}

class EquipmentSystemReattachItem extends DelayCallback {
    protected let m_data: ref<EquipmentSystemPlayerData>;
    protected let m_slotID: TweakDBID;
    protected let m_itemID: ItemID;

    public func Call() {
        let transactionSystem = GameInstance.GetTransactionSystem(this.m_data.m_owner.GetGame());
        transactionSystem.AddItemToSlot(this.m_data.m_owner, this.m_slotID, this.m_itemID, true);
    }

    public static func Create(data: ref<EquipmentSystemPlayerData>, slotID: TweakDBID, itemID: ItemID) -> ref<EquipmentSystemReattachItem> {
        let self = new EquipmentSystemReattachItem();
        self.m_data = data;
        self.m_slotID = slotID;
        self.m_itemID = itemID;

        return self;
    }
}

@addField(gameuiInGameMenuGameController)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(gameuiInGameMenuGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetPlayerControlledObject().GetGame());
}

@wrapMethod(gameuiInGameMenuGameController)
protected cb func OnPuppetReady(sceneName: CName, puppet: ref<gamePuppet>) -> Bool {
    wrappedMethod(sceneName, puppet);

    if this.m_outfitSystem.IsActive() && Equals(sceneName, n"inventory") && !GetPlayer(puppet.GetGame()).IsReplacer() {
        this.m_outfitSystem.EquipPuppetOutfit(puppet) ;
    }
}

@wrapMethod(gameuiInGameMenuGameController)
protected cb func OnEquipmentChanged(value: Variant) -> Bool {
    if !this.m_outfitSystem.UpdatePuppetFromBlackboard(this.GetPuppet(n"inventory")) {
        wrappedMethod(value);
    }
}

@addField(gameuiInventoryGameController)
private let m_outfitSystem: wref<OutfitSystem>;

@addField(gameuiInventoryGameController)
private let m_wardrobeButton: wref<inkWidget>;

@addField(gameuiInventoryGameController)
private let m_wardrobePopup: ref<inkGameNotificationToken>;

@addField(gameuiInventoryGameController)
private let m_wardrobeReady: Bool;

@wrapMethod(gameuiInventoryGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetPlayerControlledObject().GetGame());
}

@wrapMethod(gameuiInventoryGameController)
protected cb func OnUninitialize() -> Bool {
    wrappedMethod();

    this.m_wardrobeButton.UnregisterFromCallback(n"OnClick", this, n"OnWardrobeBtnClick");
}

@replaceMethod(gameuiInventoryGameController)
private final func SetupSetButton() -> Void {
    let btnWrapper = this.GetChildWidgetByPath(n"default_wrapper/menuLinks") as inkCompoundWidget;
    let btnList = this.GetChildWidgetByPath(n"default_wrapper/menuLinks/btnsContainer") as inkCompoundWidget;

    btnList.GetWidgetByIndex(3).SetVisible(false);
    btnList.GetWidgetByIndex(4).SetVisible(false);

    this.m_wardrobeButton = this.SpawnFromLocal(btnList, n"HyperlinkButton:EquipmentEx.WardrobeHubLinkController");
    this.m_wardrobeButton.RegisterToCallback(n"OnClick", this, n"OnWardrobeBtnClick");

    let btnSpacing = btnList.GetChildMargin();
    btnWrapper.SetHeight(btnWrapper.GetHeight() + this.m_wardrobeButton.GetHeight() + btnSpacing.top);

    let fluff = btnWrapper.GetWidget(n"buttonFluff2");
    fluff.SetAnchor(inkEAnchor.BottomLeft);
    fluff.SetMargin(inkMargin(0, 0, 0, 4.0));

    inkWidgetRef.SetVisible(this.m_btnSets, false);
}

@addMethod(gameuiInventoryGameController)
protected cb func OnWardrobeBtnClick(evt: ref<inkPointerEvent>) -> Bool {
    if evt.IsAction(n"click") {
        this.ShowWardrobeScreen();
    }
}

@addMethod(gameuiInventoryGameController)
protected cb func OnWardrobePopupClose(data: ref<inkGameNotificationData>) {
    this.m_wardrobePopup = null;
}

@wrapMethod(gameuiInventoryGameController)
protected cb func OnBack(userData: ref<IScriptable>) -> Bool {
    if this.m_wardrobeReady && IsDefined(this.GetChildWidgetByPath(n"wardrobe")) {
        return this.HideWardrobeScreen();
    } else {
        return wrappedMethod(userData);
    }
}

@addMethod(gameuiInventoryGameController)
protected func ShowWardrobeScreen() -> Bool {
    if !CompatibilityManager.CheckRequirements() {
        this.m_wardrobePopup = RequirementsPopup.Show(this);
        this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
        return false;
    }

    if IsDefined(this.GetChildWidgetByPath(n"wardrobe")) {
        return false;
    }

    let wardrobe = this.SpawnFromExternal(this.GetRootCompoundWidget(), r"equipment_ex\\gui\\wardrobe.inkwidget", n"Root:EquipmentEx.WardrobeScreenController") as inkCompoundWidget;
    
    if !IsDefined(wardrobe) {
        this.m_wardrobePopup = ArchivePopup.Show(this);
        this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
        return false;
    }

    wardrobe.SetName(n"wardrobe");

    let alphaAnim = new inkAnimTransparency();
    alphaAnim.SetStartTransparency(0.0);
    alphaAnim.SetEndTransparency(1.0);
    alphaAnim.SetType(inkanimInterpolationType.Linear);
    alphaAnim.SetMode(inkanimInterpolationMode.EasyOut);
    alphaAnim.SetDuration(0.8);
    
    let animDef = new inkAnimDef();
    animDef.AddInterpolator(alphaAnim);

    wardrobe.GetWidgetByPathName(n"wrapper/wrapper").PlayAnimation(animDef);

    this.m_wardrobeReady = true;

    if Equals(this.m_mode, InventoryModes.Item) {
        this.PlayShowHideItemChooserAnimation(false);
    } else {
        this.PlayLibraryAnimation(n"default_wrapper_outro");
    }

    this.GetChildWidgetByPath(n"wardrobe/wrapper/preview").SetVisible(false);
    this.PlaySlidePaperdollAnimationToOutfit();

    this.m_buttonHintsController.Hide();

    let evt = new DropQueueUpdatedEvent();
    evt.m_dropQueue = this.m_itemModeLogicController.m_itemDropQueue;
    wardrobe.GetController().QueueEvent(evt);

    this.m_itemModeLogicController.m_isWardrobeScreen = true;

    return true;
}


@addMethod(gameuiInventoryGameController)
protected func HideWardrobeScreen() -> Bool {
    if !this.m_wardrobeReady {
        return false;
    }

    let wardrobe = this.GetChildWidgetByPath(n"wardrobe") as inkCompoundWidget;

    this.m_wardrobeReady = false;
    
    let alphaAnim = new inkAnimTransparency();
    alphaAnim.SetStartTransparency(1.0);
    alphaAnim.SetEndTransparency(0.0);
    alphaAnim.SetType(inkanimInterpolationType.Linear);
    alphaAnim.SetMode(inkanimInterpolationMode.EasyOut);
    alphaAnim.SetDuration(0.3);
    
    let animDef = new inkAnimDef();
    animDef.AddInterpolator(alphaAnim);

    let animProxy = wardrobe.GetWidgetByPathName(n"wrapper/wrapper").PlayAnimation(animDef);
    animProxy.RegisterToCallback(inkanimEventType.OnFinish, this, n"OnWardrobeScreenHidden");

    if Equals(this.m_mode, InventoryModes.Item) {
        this.SwapMode(InventoryModes.Default);
        this.m_itemModeLogicController.m_isShown = false;
    }

    this.PlayLibraryAnimation(n"default_wrapper_Intro");

    this.GetChildWidgetByPath(n"wardrobe/wrapper/preview").SetVisible(false);
    inkWidgetRef.SetVisible(this.m_paperDollWidget, true);

    this.PlaySlidePaperdollAnimation(PaperdollPositionAnimation.Center, false);
    this.ZoomCamera(EnumInt(InventoryPaperdollZoomArea.Default));

    this.m_buttonHintsController.Show();

    this.m_itemModeLogicController.m_isWardrobeScreen = false;

    return true;
}

@addMethod(gameuiInventoryGameController)
protected cb func OnWardrobeScreenHidden(anim: ref<inkAnimProxy>) {
    this.GetRootCompoundWidget().RemoveChildByName(n"wardrobe");
}

@addMethod(gameuiInventoryGameController)
protected final func PlaySlidePaperdollAnimationToOutfit() {
    let outfitPreview = this.GetChildWidgetByPath(n"wardrobe/wrapper/preview");
    let outfitPreviewMargin = outfitPreview.GetMargin();

    let translationInterpolator = new inkAnimTranslation();
    translationInterpolator.SetDuration(0.2);
    translationInterpolator.SetDirection(inkanimInterpolationDirection.FromTo);
    translationInterpolator.SetType(inkanimInterpolationType.Linear);
    translationInterpolator.SetMode(inkanimInterpolationMode.EasyIn);
    translationInterpolator.SetStartTranslation(inkWidgetRef.GetTranslation(this.m_paperDollWidget));
    translationInterpolator.SetEndTranslation(Vector2(outfitPreviewMargin.left, 0.00));

    let translationAnimation = new inkAnimDef();
    translationAnimation.AddInterpolator(translationInterpolator);

    let animProxy = inkWidgetRef.PlayAnimation(this.m_paperDollWidget, translationAnimation);
    animProxy.RegisterToCallback(inkanimEventType.OnFinish, this, n"OnPaperDollSlideComplete");
}

@addMethod(gameuiInventoryGameController)
protected cb func OnPaperDollSlideComplete(anim: ref<inkAnimProxy>) {
    inkWidgetRef.SetVisible(this.m_paperDollWidget, false);
    this.GetChildWidgetByPath(n"wardrobe/wrapper/preview").SetVisible(true);
}

@wrapMethod(gameuiInventoryGameController)
protected cb func OnEquipmentClick(evt: ref<ItemDisplayClickEvent>) -> Bool {
    if IsDefined(this.GetChildWidgetByPath(n"wardrobe")) {
        return false;
    }

    if evt.actionName.IsAction(n"unequip_item") && Equals(evt.display.GetEquipmentArea(), gamedataEquipmentArea.Outfit) && this.m_outfitSystem.IsActive() {
        this.m_outfitSystem.Deactivate();
    } else {
        wrappedMethod(evt);
    }
}

@replaceMethod(gameuiInventoryGameController)
private final func RefreshEquippedWardrobeItems() {
    ArrayClear(this.m_wardrobeOutfitAreas);

    if this.m_outfitSystem.IsActive() {
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.Head);
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.Face);
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.OuterChest);
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.InnerChest);
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.Legs);
        ArrayPush(this.m_wardrobeOutfitAreas, gamedataEquipmentArea.Feet);
    }
}

enum PhotoModeUI {
    CharacterPage = 2,
    VisibilityAttribute = 27,
    ExpressionAttribute = 28,
    OutfitAttribute = 3301,
    NoOutfitOption = 3302,
    CurrentOutfitOption = 3303
}

@addField(gameuiPhotoModeMenuController)
private let m_outfitSystem: wref<OutfitSystem>;

@addField(gameuiPhotoModeMenuController)
private let m_paperdollHelper: wref<PaperdollHelper>;

@addField(gameuiPhotoModeMenuController)
private let m_outfitAttribute: Uint32;

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetPlayerControlledObject().GetGame());
    this.m_paperdollHelper = PaperdollHelper.GetInstance(this.GetPlayerControlledObject().GetGame());
    this.m_outfitAttribute = Cast<Uint32>(EnumInt(PhotoModeUI.OutfitAttribute));
}

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnAddMenuItem(label: String, attribute: Uint32, page: Uint32) -> Bool {
    wrappedMethod(label, attribute, page);

    if Equals(page, Cast<Uint32>(EnumInt(PhotoModeUI.CharacterPage))) && Equals(attribute, Cast<Uint32>(EnumInt(PhotoModeUI.VisibilityAttribute))) {
        this.AddMenuItem(StrUpper(GetLocalizedTextByKey(n"UI-Inventory-Labels-Outfit")), this.m_outfitAttribute, page, false);
    }
}

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnShow(reversedUI: Bool) -> Bool {
    let outfitMenuItem = this.GetMenuItem(this.m_outfitAttribute);
    if IsDefined(outfitMenuItem) {
        let outfits = this.m_outfitSystem.GetOutfits();
        let active = this.m_outfitSystem.IsActive();
        let options: array<PhotoModeOptionSelectorData>;
        let current: Int32 = 0;
        
        ArrayResize(options, ArraySize(outfits) + (active ? 2 : 1));

        options[0].optionText = GetLocalizedTextByKey(n"UI-Wardrobe-NoOutfit");
        options[0].optionData = EnumInt(PhotoModeUI.NoOutfitOption);

        if active {
            options[1].optionText = GetLocalizedTextByKey(n"UI-Wardrobe-CurrentOutfit");
            options[1].optionData = EnumInt(PhotoModeUI.CurrentOutfitOption);
        }

        let i = (active ? 2 : 1);
        for outfitName in outfits {
            options[i].optionText = NameToString(outfitName); // StrUpper()
            options[i].optionData = i;

            if this.m_outfitSystem.IsEquipped(outfitName) {
                current = options[i].optionData;
            }

            i += 1;
        }

        if current == 0 {
            current = options[active ? 1 : 0].optionData;
        }

        outfitMenuItem.m_photoModeController = this;
        outfitMenuItem.SetupOptionSelector(options, current);
        outfitMenuItem.SetIsEnabled(true);

        this.GetChildWidgetByPath(n"options_panel").SetHeight(1000.0);
        this.GetChildWidgetByPath(n"options_panel/horizontalMenu").SetMargin(0.0, 0.0, -10.0, 920.0);
    }

    wrappedMethod(reversedUI);
}

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnSetAttributeOptionEnabled(attribute: Uint32, enabled: Bool) -> Bool {
    wrappedMethod(attribute, enabled);

    if Equals(attribute, Cast<Uint32>(EnumInt(PhotoModeUI.ExpressionAttribute))) {
        let outfitMenuItem = this.GetMenuItem(this.m_outfitAttribute);
        if IsDefined(outfitMenuItem) {
            outfitMenuItem.SetIsEnabled(enabled);
        }
    }
}

@addMethod(gameuiPhotoModeMenuController)
public func OnAttributeOptionSelected(attribute: Uint32, option: PhotoModeOptionSelectorData) {
    if Equals(attribute, Cast<Uint32>(EnumInt(PhotoModeUI.OutfitAttribute))) {
        let optionCase = IntEnum<PhotoModeUI>(option.optionData);
        switch optionCase {
            case PhotoModeUI.NoOutfitOption:
                this.m_outfitSystem.EquipPuppetOutfit(this.m_paperdollHelper.GetPuppet(), false);
                break;
            case PhotoModeUI.CurrentOutfitOption:
                this.m_outfitSystem.EquipPuppetOutfit(this.m_paperdollHelper.GetPuppet(), true);
                break;
            default:
                let outfitName = StringToName(option.optionText);
                this.m_outfitSystem.EquipPuppetOutfit(this.m_paperdollHelper.GetPuppet(), outfitName);
                break;
        }
    }
}

@wrapMethod(PhotoModeMenuListItem)
private final func StartArrowClickedEffect(widget: inkWidgetRef) {
    wrappedMethod(widget);

    this.m_photoModeController.OnAttributeOptionSelected(
        (this.GetData() as PhotoModeMenuListItemData).attributeKey, 
        this.m_OptionSelectorValues[this.m_OptionSelector.GetCurrIndex()]
    );
}

@wrapMethod(inkInventoryPuppetPreviewGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    PaperdollHelper.GetInstance(this.GetPlayerControlledObject().GetGame()).AddPreview(this);
}

@addMethod(inkScrollController)
public func SetScrollEnabled(enabled: Bool) {
    if enabled {
        if Equals(this.direction, inkEScrollDirection.Horizontal) {
            this.scrollDelta = this.contentSize.X - this.viewportSize.X;
        } else {
            this.scrollDelta = this.contentSize.Y - this.viewportSize.Y;
        }
    } else {
        this.scrollDelta = 0.0;
    }
}

@addField(InventoryItemDisplayController)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(InventoryItemDisplayController)
public func Bind(inventoryDataManager: ref<InventoryDataManagerV2>, equipmentArea: gamedataEquipmentArea, opt slotIndex: Int32, opt displayContext: ItemDisplayContext, opt setWardrobeOutfit: Bool, opt wardrobeOutfitIndex: Int32) {
    this.m_outfitSystem = OutfitSystem.GetInstance(inventoryDataManager.GetGame());

    wrappedMethod(inventoryDataManager, equipmentArea, slotIndex, displayContext, setWardrobeOutfit, wardrobeOutfitIndex);
}

@wrapMethod(InventoryItemDisplayController)
public func Bind(inventoryScriptableSystem: ref<UIInventoryScriptableSystem>, equipmentArea: gamedataEquipmentArea, opt slotIndex: Int32, displayContext: ItemDisplayContext) {
    this.m_outfitSystem = OutfitSystem.GetInstance(inventoryScriptableSystem.GetGameInstance());

    wrappedMethod(inventoryScriptableSystem, equipmentArea, slotIndex, displayContext);
}

@wrapMethod(InventoryItemDisplayController)
protected func RefreshUI() {
    let isOutfit = Equals(this.m_equipmentArea, gamedataEquipmentArea.Outfit);
    let isOverriden = this.m_outfitSystem.IsActive();

    if isOutfit && isOverriden {
        this.m_wardrobeOutfitIndex = 1;
    } else {
        this.m_wardrobeOutfitIndex = -1;
    }

    wrappedMethod();

    if isOutfit && isOverriden {
        inkWidgetRef.SetVisible(this.m_wardrobeInfoText, false);
        inkWidgetRef.SetVisible(this.m_slotItemsCountWrapper, false);
        inkWidgetRef.SetMargin(this.m_wardrobeInfoContainer, inkMargin(12.0, 0, 0, 12.0));
    }
}

@wrapMethod(InventoryItemDisplayController)
protected func NewUpdateRequirements(itemData: ref<UIInventoryItem>) {
    if !itemData.IsForWardrobe() {
        wrappedMethod(itemData);
    }
}

@addField(InventoryItemModeLogicController)
private let m_outfitSystem: wref<OutfitSystem>;

@addField(InventoryItemModeLogicController)
public let m_isWardrobeScreen: Bool;

@wrapMethod(InventoryItemModeLogicController)
public final func SetupData(buttonHints: wref<ButtonHints>, tooltipsManager: wref<gameuiTooltipsManager>, inventoryManager: ref<InventoryDataManagerV2>, player: wref<PlayerPuppet>) {
     wrappedMethod(buttonHints, tooltipsManager, inventoryManager, player);

     this.m_outfitSystem = OutfitSystem.GetInstance(this.m_player.GetGame());
}

@replaceMethod(InventoryItemModeLogicController)
private final func UpdateOutfitWardrobe(active: Bool, activeSetOverride: Int32) {
    inkWidgetRef.SetVisible(this.m_wardrobeSlotsContainer, active);
    inkWidgetRef.SetVisible(this.m_wardrobeSlotsLabel, active);
    inkWidgetRef.SetVisible(this.m_outfitsFilterInfoText, active);
    inkWidgetRef.SetVisible(this.m_filterButtonsGrid, !active);

    if active && !this.m_outfitWardrobeSpawned {
        let wardrobeContainer = inkWidgetRef.Get(this.m_wardrobeSlotsContainer) as inkCompoundWidget;

        let wardrobeInfo = new inkText();
        wardrobeInfo.SetLocalizedTextString("UI-Wardrobe-Tooltip-OutfitInfo");
        wardrobeInfo.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        wardrobeInfo.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
        wardrobeInfo.BindProperty(n"tintColor", n"MainColors.Red");
        wardrobeInfo.BindProperty(n"fontWeight", n"MainColors.BodyFontWeight");
        wardrobeInfo.BindProperty(n"fontSize", n"MainColors.ReadableXSmall");
        wardrobeInfo.SetWrapping(true, 660.0);
        wardrobeInfo.Reparent(wardrobeContainer);


        let wardrobeBtn = this.SpawnFromLocal(wardrobeContainer, n"wardrobeOutfitSlot:EquipmentEx.WardrobeHubBtnController");
        wardrobeBtn.SetMargin(inkMargin(16.0, 0.0, 0.0, 0.0));

        this.m_outfitWardrobeSpawned = true;
    }
}

@replaceMethod(InventoryItemModeLogicController)
protected cb func OnWardrobeOutfitSlotClicked(e: ref<WardrobeOutfitSlotClickedEvent>) -> Bool {
    this.m_inventoryController.ShowWardrobeScreen();
}

@replaceMethod(InventoryItemModeLogicController)
protected cb func OnWardrobeOutfitSlotHoverOver(e: ref<WardrobeOutfitSlotHoverOverEvent>) -> Bool {
}

@wrapMethod(InventoryItemModeLogicController)
protected cb func OnItemDisplayClick(evt: ref<ItemDisplayClickEvent>) -> Bool {
    if !this.m_isWardrobeScreen {
        wrappedMethod(evt);
    }
}

@wrapMethod(InventoryItemModeLogicController)
protected cb func OnItemDisplayHoverOver(evt: ref<ItemDisplayHoverOverEvent>) -> Bool {
    if !this.m_isWardrobeScreen {
        wrappedMethod(evt);
    }
}

@wrapMethod(InventoryItemModeLogicController)
private final func SetInventoryItemButtonHintsHoverOver(const displayingData: script_ref<InventoryItemData>,
                                                        opt display: ref<InventoryItemDisplayController>) {
    wrappedMethod(displayingData, display);

    if this.m_outfitSystem.IsActive() {
        let equipmentArea = InventoryItemData.GetEquipmentArea(displayingData);
        let isClothing = this.IsEquipmentAreaClothing(equipmentArea) || Equals(equipmentArea, gamedataEquipmentArea.Outfit);
        if isClothing {
            this.m_buttonHintsController.RemoveButtonHint(n"preview_item");
        }
    }
}

@wrapMethod(InventoryItemModeLogicController)
private final func HandleItemClick(const itemData: script_ref<InventoryItemData>, actionName: ref<inkActionName>, opt displayContext: ItemDisplayContext, opt isPlayerLocked: Bool) {
    if this.m_outfitSystem.IsActive() && actionName.IsAction(n"preview_item") {
        let equipmentArea = InventoryItemData.GetEquipmentArea(itemData);
        let isClothing = this.IsEquipmentAreaClothing(equipmentArea) || Equals(equipmentArea, gamedataEquipmentArea.Outfit);
        if isClothing {
            return;
        }
    }

    wrappedMethod(itemData, actionName, displayContext, isPlayerLocked);
}

@addField(PhotoModePlayerEntityComponent)
private let m_outfitSystem: wref<OutfitSystem>;

@addField(PhotoModePlayerEntityComponent)
private let m_paperdollHelper: wref<PaperdollHelper>;

@wrapMethod(PhotoModePlayerEntityComponent)
private final func OnGameAttach() {
    wrappedMethod();

    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetOwner().GetGame());
    this.m_paperdollHelper = PaperdollHelper.GetInstance(this.GetOwner().GetGame());
}

@wrapMethod(PhotoModePlayerEntityComponent)
private final func SetupInventory(isCurrentPlayerObjectCustomizable: Bool) {
    wrappedMethod(isCurrentPlayerObjectCustomizable);

    if this.customizable {
        this.m_paperdollHelper.AddPuppet(this.fakePuppet);

        if this.m_outfitSystem.IsActive() {
            this.m_outfitSystem.EquipPuppetOutfit(this.fakePuppet, this.loadingItems);
        }
    }
}

@wrapMethod(PhotoModePlayerEntityComponent)
protected cb func OnItemAddedToSlot(evt: ref<ItemAddedToSlot>) -> Bool {
    if this.m_outfitSystem.IsActive() {
        ArrayRemove(this.loadingItems, evt.GetItemID());
    } else {
        wrappedMethod(evt);
    }
}

@wrapMethod(PopupsManager)
private final func ShowTutorial() {
    if Equals(this.m_tutorialData.message, "LocKey#86091") || Equals(this.m_tutorialData.message, "LocKey#86092") {
        this.OnPopupCloseRequest(null);
        return;
    }

    wrappedMethod();
}

@addField(QuestTrackerGameController)
private let m_wardrobePopup: ref<inkGameNotificationToken>;

@wrapMethod(QuestTrackerGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    if !CompatibilityManager.IsUserNotified() {
        if !CompatibilityManager.CheckRequirements() {
            this.m_wardrobePopup = RequirementsPopup.Show(this);
            this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
        } else {
            if !CompatibilityManager.CheckConflicts(this.m_player.GetGame()) {
                this.m_wardrobePopup = ConflictsPopup.Show(this);
                this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
            }
        }
        CompatibilityManager.MarkAsNotified();
    }
}

@addMethod(QuestTrackerGameController)
protected cb func OnWardrobePopupClose(data: ref<inkGameNotificationData>) {
    this.m_wardrobePopup = null;
}

@addMethod(Stash)
protected cb func OnGameAttached() -> Bool {
    InventoryHelper.GetInstance(this.GetGame()).AddStash(this);
}

@addMethod(UIInventoryItem)
public static func Make(owner: wref<GameObject>, slotID: TweakDBID, itemData: script_ref<InventoryItemData>, opt manager: wref<UIInventoryItemsManager>) -> ref<UIInventoryItem> {
    let self = UIInventoryItem.FromInventoryItemData(owner, itemData, manager);
    self.m_data.IconPath = UIInventoryItemsManager.ResolveItemIconName(self.m_itemTweakID, self.m_itemRecord, self.m_manager);
    self.m_slotID = slotID;

    return self;
}

@addMethod(UIInventoryItem)
public func IsForWardrobe() -> Bool {
    return TDBID.IsValid(this.m_slotID);
}

@wrapMethod(UIInventoryItem)
public final func IsEquipped(opt force: Bool) -> Bool {
    if this.IsForWardrobe() && IsDefined(this.m_manager) {
        return this.m_manager.IsItemEquippedInSlot(this.ID, this.m_slotID);
    }

    return wrappedMethod(force);
}

@wrapMethod(UIInventoryItem)
public final func IsTransmogItem() -> Bool {
    if this.IsForWardrobe()  {
        return false;
    }

    return wrappedMethod();
}

@addField(UIInventoryItemsManager)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(UIInventoryItemsManager)
public final static func Make(player: wref<PlayerPuppet>, transactionSystem: ref<TransactionSystem>, uiScriptableSystem: wref<UIScriptableSystem>) -> ref<UIInventoryItemsManager> {
    let instance = wrappedMethod(player, transactionSystem, uiScriptableSystem);
    instance.m_outfitSystem = OutfitSystem.GetInstance(player.GetGame());

    return instance;
}

@addMethod(UIInventoryItemsManager)
public final func IsItemEquippedInSlot(itemID: ItemID, slotID: TweakDBID) -> Bool {
    return this.m_outfitSystem.IsActive() ? this.m_outfitSystem.IsEquipped(itemID) : this.IsItemEquipped(itemID);
}

@wrapMethod(UIInventoryItemsManager)
public final func IsItemTransmog(itemID: ItemID) -> Bool {
    return this.m_outfitSystem.IsActive() && this.m_outfitSystem.IsEquipped(itemID);
}

@addField(WardrobeSetPreviewGameController)
private let m_outfitSystem: wref<OutfitSystem>;

@wrapMethod(WardrobeSetPreviewGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    let cameraSetup: gameuiPuppetPreviewCameraSetup;
    cameraSetup.slotName = n"UISlotPreview_UpperBody";
    cameraSetup.cameraZoom = 1.85;
    cameraSetup.interpolationTime = 1;

    ArrayResize(this.cameraController.cameraSetup, Cast<Int32>(EnumGetMax(n"InventoryPaperdollZoomArea") + 1l));
    this.cameraController.cameraSetup[EnumInt(InventoryPaperdollZoomArea.Head)] = cameraSetup;
}

@wrapMethod(WardrobeSetPreviewGameController)
protected cb func OnPreviewInitialized() -> Bool {
    this.m_outfitSystem = OutfitSystem.GetInstance(this.GetGamePuppet().GetGame());

    if this.m_isNotification && this.m_outfitSystem.IsActive() {
        this.m_outfitSystem.EquipPuppetOutfit(this.GetGamePuppet());
        this.m_outfitSystem.EquipPuppetItem(this.GetGamePuppet(), this.m_data.itemID);
    } else {
        wrappedMethod();
    }
}

@wrapMethod(WardrobeSetPreviewGameController)
public final func RestorePuppetEquipment() {
    wrappedMethod();

    if this.m_outfitSystem.IsActive() {
        this.m_outfitSystem.EquipPuppetOutfit(this.GetGamePuppet());
    }
}

@addField(WardrobeUIGameController)
private let m_wardrobePopup: ref<inkGameNotificationToken>;

@replaceMethod(WardrobeUIGameController)
protected cb func OnInitialize() -> Bool {
    this.GetChildWidgetByPath(n"mainScreenContainer").SetVisible(false);
    this.GetChildWidgetByPath(n"setEditorScreenContainer").SetVisible(false);
    this.GetChildWidgetByPath(n"constantContainer/paperDoll").SetVisible(false);

    if !CompatibilityManager.CheckRequirements() {
        this.m_wardrobePopup = RequirementsPopup.Show(this);
        this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
    } else {
        let wardrobe = this.SpawnFromExternal(this.GetRootCompoundWidget(), r"equipment_ex\\gui\\wardrobe.inkwidget", n"Root:EquipmentEx.WardrobeScreenController");
        if !IsDefined(wardrobe) {
            this.m_wardrobePopup = ArchivePopup.Show(this);
            this.m_wardrobePopup.RegisterListener(this, n"OnWardrobePopupClose");
            return false;
        }
    }

    this.m_introAnimProxy = new inkAnimProxy();
}

@replaceMethod(WardrobeUIGameController)
protected cb func OnBack(userData: ref<IScriptable>) -> Bool {
    this.m_menuEventDispatcher.SpawnEvent(n"OnWardrobeClose");
}

@replaceMethod(WardrobeUIGameController)
private final func CloseWardrobe() -> Void {
    this.m_menuEventDispatcher.SpawnEvent(n"OnWardrobeClose");
}

@addMethod(WardrobeUIGameController)
protected cb func OnWardrobePopupClose(data: ref<inkGameNotificationData>) {
    this.m_wardrobePopup = null;
    this.m_menuEventDispatcher.SpawnEvent(n"OnWardrobeClose");
}
