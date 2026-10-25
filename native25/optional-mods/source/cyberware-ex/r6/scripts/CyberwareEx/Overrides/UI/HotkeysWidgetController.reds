@wrapMethod(HotkeysWidgetController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    this.FixHudSlotSize();
    this.SpawnCyberwareExtraSlots();
}

@addMethod(HotkeysWidgetController)
protected func SpawnCyberwareExtraSlots() {
    let container = inkWidgetRef.Get(this.m_dpadHintsPanel) as inkCompoundWidget;

    let cyberwarePos = 0;
    let cyberwareWidget: wref<inkWidget>;
    let numWidgets = container.GetNumChildren();
    while cyberwarePos < container.GetNumChildren() {
        cyberwareWidget = container.GetWidgetByIndex(cyberwarePos);
        if Equals(cyberwareWidget.GetName(), n"cyberware") {
            break;
        }

        cyberwarePos += 1;
    }

    if cyberwarePos >= numWidgets {
        return;
    }

    let cyberwares = [cyberwareWidget];
    ArrayPush(cyberwares, this.SpawnFromLocal(container, n"cyberware"));
    ArrayPush(cyberwares, this.SpawnFromLocal(container, n"cyberware"));

    let i = 0;
    let cyberwareTypes = [n"Cyberdeck", n"Sandevistan", n"Berserk"];
    while i < ArraySize(cyberwareTypes) {
        cyberwares[i].SetName(cyberwareTypes[i]);
        if i >= 1 {
            container.ReorderChild(cyberwares[i], cyberwarePos + i);
        }
        i += 1;
    }

    // TODO: Adjust input hints
}

@if(ModuleExists("CustomQuickslots"))
@addMethod(HotkeysWidgetController)
protected func FixHudSlotSize() {}

@if(!ModuleExists("CustomQuickslots"))
@addMethod(HotkeysWidgetController)
protected func FixHudSlotSize() {
    let hudEntryInfo = this.GetRootWidget().GetUserData(n"inkHudEntryInfo") as inkHudEntryInfo;
    hudEntryInfo.size = Vector2(2400, 300);
}
