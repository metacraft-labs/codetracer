## menu_keys.nim — PLAT-68 Phase B: how the desktop's key router reaches
## the program menu (CUA-Keymap.md §3.8) without importing it.
##
## `ui/menu` (the menu component) installs these when it renders;
## `ui/key_router` calls them. A leaf, because `ui/menu` sits above the
## router in the import graph and the router must not reach up into it.
##
## While the menu is open it owns its keys — the arrows, `Enter`, `Escape`
## and type-to-select — as the terminal's and GPUI's menus do; the keymap's
## own menu keys (`Alt`, `` Alt+` ``, `Alt+<mnemonic>`, `F10` in Edit mode)
## keep their meaning there and come through `operation`.

type
  MenuAccess* = object
    isOpen*: proc(): bool
      ## Whether the menu is showing.
    key*: proc(name: string): bool
      ## The open menu's own key, by canonical name; answers whether it was
      ## taken.
    operation*: proc(operation, argument: string)
      ## `menu.open`, `menu.toggle` or `menu.open-folder(<argument>)`.

var menuAccess*: MenuAccess
  ## Set by the menu component; all nil until it has rendered once.

const MenuOperations* = ["menu.open", "menu.toggle", "menu.open-folder"]
  ## The operations `operation` performs.

proc menuIsOpen*(): bool =
  not menuAccess.isOpen.isNil and menuAccess.isOpen()
