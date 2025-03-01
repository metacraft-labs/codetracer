function Calltrace() {
    var data = { trace: { lang: 1 } }; //useState('data', {});
    if (data.trace === undefined) {
        return (React.createElement("div", null));
    }
    return (React.createElement("div", { className: 'calltrace-view' },
        React.createElement(SearchCalltraceView, null),
        React.createElement(LocalCalltraceView, null)));
}
function SearchCalltraceView(props) {
    return (React.createElement("div", { className: "calltrace-search" },
        React.createElement("form", { id: 'calltrace-search-form' },
            React.createElement("input", { type: "text", placeholder: "search" }))));
}
function LocalCallView(props) {
    var kl = "call-current";
    // let ret = call.returnValue
    // let args = call.args
    var name = 'calltrace-' + props.call;
    var style = "margin-left" + props.depth + "px";
    return (React.createElement("div", { id: name, className: "calltrace-child call-depth" },
        React.createElement("div", { className: "call-offset" }, " "),
        React.createElement("div", { className: "call-name" },
            React.createElement("div", { className: "call-text" }, props.call))));
}
function LocalCallstackView(props) {
    // var high = self.callstack.high
    // let low = self.callstack.low
    //     for index in countdown(high, low):
    //       var call = self.callstack[index]
    //       localCallView(self, call, self.callstack.len - index - 1)
    //       # depth = self.callstack.len - index
    // else:
    //   text ""
    return (React.createElement(LocalCallView, { call: 'a', depth: 0 }));
}
function LocalCalltraceView(props) {
    // TODO: sometimes we might not have some calls from callstack in calltrace
    // thats why we can somehow record NimMainModule/main etc
    console.log(window.data);
    return (React.createElement("div", { className: 'local-calltrace' },
        React.createElement(LocalCallstackView, null)));
    //         if self.data.config.calltrace and self.data.trace.calltrace:
    //           if not self.slice.isNil:
    //     for call in self.slice.root:
    //       if call.isNil:
    //         continue
    //       localCallView(self, call, 0)
    // elif not self.service.currentCall.isNil:
    //   for call in self.service.currentCall.children:
    //     localCallView(self, call, 1)
}
setTimeout(function () {
    var calltraceElement = document.querySelector('#calltraceComponent-0');
    ReactDOM.render(React.createElement(Calltrace, null), calltraceElement);
}, 5000);
// we can access local data, but maybe this would confuse react?
// or just call re-draw after each redrawAll?
// based on our events etc
// call this from layout
