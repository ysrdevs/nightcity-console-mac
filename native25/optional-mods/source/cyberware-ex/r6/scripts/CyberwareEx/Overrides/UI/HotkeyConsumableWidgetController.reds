@wrapMethod(HotkeyConsumableWidgetController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    let container = inkWidgetRef.Get(this.m_container) as inkCompoundWidget;
    container.GetWidgetByIndex(container.GetNumChildren() - 1).SetName(n"Sandevistan");
}
