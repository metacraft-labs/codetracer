type
  MacroExpansionLevelBase* = enum
    MacroExpansionTopLevel,
    MacroExpansionDeepest

  MacroExpansionLevel* = object
    base*: MacroExpansionLevelBase
    level*: int ## only for MacroExpansionTopLevel

  MacroExpansionUpdateKind* = enum
    MacroUpdateExpand, ## expand <number>: Expand <times>
    MacroUpdateExpandAll,  ## expand all: ExpandAll
    MacroUpdateCollapse,  ## collapse <number>: Collapse <times>|
    MacroUpdateCollapseAll  ## collapse all: CollapseAll

  MacroExpansionLevelUpdate* = object
    kind*: MacroExpansionUpdateKind
    times*: int ## used only in MacroUpdateExpand and MacroUpdateCollapse

  MacroExpansion* = object
    path*: langstring
    definition*: langstring
    line*: int
    isDefinition*: bool
