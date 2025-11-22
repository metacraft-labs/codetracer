import ../utils, ../../common/ct_event, value, ui_imports

method render*(self: AgentActivityComponent): VNode =
    result = buildHtml(
        tdiv(class = componentContainerClass("agent-view"))
    ):
        tdiv(class = "log-list"):
            for entry in self.logData:
                tdiv(class = "log-item"):
                    tdiv(class = "log-title"): text fmt"⦿ {entry.title}"

                    if entry.output.len > 0:
                        let statusClass = "log-output status-" & entry.status
                        tdiv(class = statusClass):
                            text entry.output