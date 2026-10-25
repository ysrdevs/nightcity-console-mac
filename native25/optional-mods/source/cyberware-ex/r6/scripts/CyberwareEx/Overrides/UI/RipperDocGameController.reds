import CyberwareEx.*

@wrapMethod(RipperDocGameController)
private final func Init() {
    wrappedMethod();

    let text = new inkText();
    text.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
    text.SetFontStyle(n"Regular");
    text.SetFontSize(28);
    text.SetOpacity(0.1);
    text.SetAnchor(inkEAnchor.TopRight);
    text.SetAnchorPoint(Vector2(1.0, 0.0));
    text.SetMargin(inkMargin(0, 160, 100, 0));
    text.SetHorizontalAlignment(textHorizontalAlignment.Left);
    text.SetVerticalAlignment(textVerticalAlignment.Top);
    text.SetStyle(r"base\\gameplay\\gui\\common\\main_colors.inkstyle");
    text.BindProperty(n"tintColor", n"MainColors.Red");
    text.SetText(s"POWERED BY CYBERWARE-EX \(CyberwareEx.Version())");
    text.Reparent(this.GetRootCompoundWidget());
}

@wrapMethod(RipperDocGameController)
protected cb func OnSlotClick(evt: ref<ItemDisplayClickEvent>) -> Bool {
    if this.m_isActivePanel && IsDefined(evt.uiInventoryItem) && Equals(this.m_hoverArea, gamedataEquipmentArea.EyesCW) {
        if evt.actionName.IsAction(n"unequip_item") && evt.uiInventoryItem.IsEquipped() {
            this.m_isInEquipPopup = true;
            this.UnequipCyberware(evt.uiInventoryItem.GetItemData());
            return false;
        }
    }

    wrappedMethod(evt);
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(RipperDocGameController)
private final func IsEquipmentAreaRequiringPerk(equipmentArea: gamedataEquipmentArea) -> Bool {
    let playerData = EquipmentSystem.GetData(this.GetPlayerControlledObject());
    let visibleWhenLocked: Bool;
    return playerData.IsSlotLocked(
        this.m_hoveredItemDisplay.GetEquipmentArea(),
        this.m_hoveredItemDisplay.GetSlotIndex(),
        visibleWhenLocked
    );
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
private final func ShowCWPerkTooltip(widget: wref<inkWidget>) {
    if Equals(this.m_dollHoverArea, gamedataEquipmentArea.HandsCW) {
        wrappedMethod(widget);
        return;
    }

    this.m_ripperdocHoverState = RipperdocHoverState.SlotSkeleton;

    let tooltipData = new RipperdocPerkTooltipData();
    tooltipData.equipArea = this.m_hoveredItemDisplay.GetEquipmentArea();
    tooltipData.slotIndex = this.m_hoveredItemDisplay.GetSlotIndex();
    tooltipData.ripperdocHoverState = this.m_ripperdocHoverState;

    this.m_TooltipsManager.ShowTooltipAtWidget(n"RipperdocPerkTooltip", widget, tooltipData,
        gameuiETooltipPlacement.RightTop, false, new inkMargin(this.m_defaultTooltipGap, 0.00, 0.00, 0.00));
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
protected cb func OnSlotHover(evt: ref<ItemDisplayHoverOverEvent>) -> Bool {
    this.m_hoveredItemDisplay = evt.display;
    wrappedMethod(evt);
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(RipperDocGameController)
private final func GetRequiredPerk(hoverArea: RipperdocHoverState) -> gamedataNewPerkType {
    return CyberwareHelper.GetRequiredPerkType(
        this.m_hoveredItemDisplay.GetEquipmentArea(),
        this.m_hoveredItemDisplay.GetSlotIndex()
    );
}

@if(!ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(RipperDocGameController)
private final func OpenPerkTree() {
    let userData = new PerkUserData();
    userData.cyberwareScreenType = this.m_screen;
    userData.statType = CyberwareHelper.GetRequiredPerkStatType(
        this.m_hoveredItemDisplay.GetEquipmentArea(),
        this.m_hoveredItemDisplay.GetSlotIndex()
    );
    userData.perkType = CyberwareHelper.GetRequiredPerkType(
        this.m_hoveredItemDisplay.GetEquipmentArea(),
        this.m_hoveredItemDisplay.GetSlotIndex()
    );

    if Equals(this.m_screen, CyberwareScreenType.Inventory) {
        let evt = new OpenMenuRequest();
        evt.m_menuName = n"new_perks";
        evt.m_isMainMenu = true;
        evt.m_jumpBack = true;
        evt.m_eventData.userData = userData;
        evt.m_eventData.m_overrideDefaultUserData = true;
        this.QueueBroadcastEvent(evt);
    } else {
        this.m_menuEventDispatcher.SpawnEvent(n"OnSwitchToCharacter", userData);
    }
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addField(RipperDocGameController)
private let m_overrideManager: ref<OverrideManager>;

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addField(RipperDocGameController)
private let m_overrideConfirmationToken: ref<inkGameNotificationToken>;

@if(ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
private final func Init() {
    wrappedMethod();

    this.m_overrideManager = new OverrideManager();
    this.m_overrideManager.Initialize(EquipmentSystem.GetData(this.m_player));
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
protected cb func OnSlotHover(evt: ref<ItemDisplayHoverOverEvent>) -> Bool {
    wrappedMethod(evt);

    if Equals(this.m_screen, CyberwareScreenType.Ripperdoc) {
        // let cursorContext = n"Hover";
        // let cursorData: ref<MenuCursorUserData>;

        if Equals(this.m_filterMode, RipperdocModes.Default) {
            let overrideState = this.m_overrideManager.GetOverrideState(evt.display.GetEquipmentArea());
            if overrideState.isOverridable {
                // cursorData = new MenuCursorUserData();
                // cursorData.SetAnimationOverride(n"hoverOnHoldToComplete");
                // cursorContext = n"HoldToComplete";

                if overrideState.currentSlots != overrideState.defaultSlots {
                    this.m_buttonHintsController.AddButtonHint(n"disassemble_item",
                        // "[" + GetLocalizedText("Gameplay-Devices-Interactions-Helpers-Hold") + "] " +
                        GetLocalizedText("LocKey#53485") + ": " +
                        GetLocalizedTextByKey(n"UI-ResourceExports-Reset"));
                    // cursorData.AddAction(n"disassemble_item");
                }

                if overrideState.currentSlots < overrideState.maxSlots {
                    this.m_buttonHintsController.AddButtonHint(n"drop_item",
                        // "[" + GetLocalizedText("Gameplay-Devices-Interactions-Helpers-Hold") + "] " +
                        GetLocalizedText("LocKey#53485") + ": " +
                        GetLocalizedTextByKey(n"UI-ResourceExports-Buy"));
                    // cursorData.AddAction(n"drop_item");
                }
            }
        }

        // this.SetCursorContext(cursorContext, cursorData);
    }
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
private final func SetButtonHintsUnhover() {
    wrappedMethod();

    this.m_buttonHintsController.RemoveButtonHint(n"drop_item");
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@wrapMethod(RipperDocGameController)
protected cb func OnPreviewCyberwareClick(evt: ref<inkPointerEvent>) -> Bool {
    wrappedMethod(evt);

    if Equals(this.m_screen, CyberwareScreenType.Ripperdoc) && Equals(this.m_filterMode, RipperdocModes.Default) {
        let areaType = this.GetCyberwareSlotControllerFromTarget(evt).GetEquipmentArea();
        let overrideState = this.m_overrideManager.GetOverrideState(areaType);

        switch (true) {
            case evt.IsAction(n"drop_item"):
                if overrideState.currentSlots < overrideState.maxSlots {
                    if overrideState.canBuyOverride {
                        this.m_overrideConfirmationToken = OverrideConfirmationPopup.Show(this, OverrideAction.Upgrade, overrideState);
                        this.m_overrideConfirmationToken.RegisterListener(this, n"OnSlotUpgradeConfirmed");
                    } else {
                        this.ShowNotEnoughMoneyNotification();
                    }
                }
                break;
            case evt.IsAction(n"disassemble_item"):
                if overrideState.currentSlots != overrideState.defaultSlots {
                    if overrideState.canBuyReset {
                        this.m_overrideConfirmationToken = OverrideConfirmationPopup.Show(this, OverrideAction.Reset, overrideState);
                        this.m_overrideConfirmationToken.RegisterListener(this, n"OnSlotResetConfirmed");
                    } else {
                        this.ShowNotEnoughMoneyNotification();
                    }
                }
                break;
        }
    }
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addMethod(RipperDocGameController)
protected func ShowNotEnoughMoneyNotification() {
    let notification = new UIMenuNotificationEvent();
    notification.m_notificationType = UIMenuNotificationType.VNotEnoughMoney;

    this.QueueEvent(notification);
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addMethod(RipperDocGameController)
protected cb func OnSlotUpgradeConfirmed(data: ref<inkGameNotificationData>) -> Bool {
    if OverrideConfirmationPopup.IsConfirmed(data) {
        let areaType = OverrideConfirmationPopup.GetAreaType(data);
        let vendor = NotEquals(this.m_VendorDataManager.GetVendorName(), "")
            ? this.m_VendorDataManager.GetVendorInstance()
            : null;

        this.m_overrideManager.UpgradeSlot(areaType, false, vendor);

        this.UpdateMinigrids();
        this.UpdateMoney();
    }

    this.m_overrideConfirmationToken = null;
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addMethod(RipperDocGameController)
protected cb func OnSlotResetConfirmed(data: ref<inkGameNotificationData>) -> Bool {
    if OverrideConfirmationPopup.IsConfirmed(data) {
        let areaType = OverrideConfirmationPopup.GetAreaType(data);
        let vendor = NotEquals(this.m_VendorDataManager.GetVendorName(), "")
            ? this.m_VendorDataManager.GetVendorInstance()
            : null;

        this.m_overrideManager.ResetSlot(areaType, false, vendor);

        this.UpdateMinigrids();
        this.UpdateMoney();
    }

    this.m_overrideConfirmationToken = null;
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@replaceMethod(RipperDocGameController)
private final func IsEquipmentAreaRequiringPerk(equipmentArea: gamedataEquipmentArea) -> Bool {
    return false;
}

@if(ModuleExists("CyberwareEx.OverrideMode"))
@addMethod(RipperDocGameController)
private final func UpdateMoney() {
    let blackBoardDef = GetAllBlackboardDefs().UI_Vendor;
    let blackBoard = GameInstance.GetBlackboardSystem(this.GetPlayerControlledObject().GetGame()).Get(blackBoardDef);
    blackBoard.SignalVariant(blackBoardDef.VendorData);
}
