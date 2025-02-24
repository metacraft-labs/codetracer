import jsffi, ../../../../../lib

# TODO: Static read, then JSON.parse or {.emit.} !
let codetracerWhite* = js{
                          "base": j"vs",
                          "inherit": true,
                          "rules": [
                            js{
                              "foreground": j"6e6e6e",
                              "token": j""
                            },
                            js{
                              "foreground": j"eb4f64",
                              "token": j"comment"
                            },
                            js{
                              "foreground": j"cdd3de",
                              "token": j"variable"
                            },
                            js{
                              "foreground": j"56a3e8",
                              "token": j"keyword"
                            },
                            js{
                              "foreground": j"2dc079",
                              "token": j"type"
                            },
                            js{
                              "foreground": j"0b6ae6",
                              "token": j"string"
                            },
                            js{
                              "foreground": j"#599f89",
                              "token": j"number"
                            },
                            js{
                              "foreground": j"#6e6e6e",
                              "token": j"delimiter"
                            }
                          ],
                          "colors": js{
                            "editor.foreground": j"#1e1f26",
                            "editor.background": j"#1e1f26", #1e1f26
                            "editor.selectionBackground": j"#4f5b66",
                            "editor.lineHighlightBackground": j"#65737e55",
                            "editorCursor.foreground": j"#c0c5ce",
                            "editorWhitespace.foreground": j"#65737e",
                            "editorIndentGuide.background": j"#65737F",
                            "editorIndentGuide.activeBackground": j"#FBC95A",
                            "editorSuggestWidget.foreground": j"#464646",
                            "editorSuggestWidget.background": j"#F5F5F5"
                          }
                      }


let codetracerDark* = js{
                          "base": j"vs-dark",
                          "inherit": true,
                          "rules": [
                            js{
                              "foreground": j"8e8f92",
                              "token": j""
                            },
                            js{
                              "foreground": j"a0735e",
                              "token": j"comment"
                            },
                            js{
                              "foreground": j"cdd3de",
                              "token": j"variable"
                            },
                            js{
                              "foreground": j"e48e59",
                              "token": j"keyword"
                            },
                            js{
                              "foreground": j"cd536d",
                              "token": j"type"
                            },
                            js{
                              "foreground": j"83319c",
                              "token": j"string"
                            }
                            js{
                              "foreground": j"#d55670",
                              "token": j"number"
                            },
                            js{
                              "foreground": j"#8e8f92",
                              "token": j"delimiter"
                            }
                          ],
                          "colors": js{
                            "editor.foreground": j"#CDD3DE",
                            "editor.background": j"#FFFFFF",
                            "editor.selectionBackground": j"#4f5b66",
                            "editor.lineHighlightBackground": j"#65737e55",
                            "editorCursor.foreground": j"#c0c5ce",
                            "editorWhitespace.foreground": j"#65737e",
                            "editorIndentGuide.background": j"#65737F",
                            "editorIndentGuide.activeBackground": j"#FBC95A",
                            "editorSuggestWidget.foreground": j"#8e8f92",
                            "editorSuggestWidget.background": j"#1e1f26",
                          }
                      }


# If you decide to use this way of defining custom monaco themes, it is useful to know 
# which token defines the object color you want to define.
# YOU CAN CHECK WHAT COLOR IS THE OBJECT IN THE UI AND THEN SEARCH THE TOKEN IT IS DEFINED TO
# BUILT-IN THEMES DEFINITIONS  
# {
# 	base: 'vs-dark',
# 	inherit: false,
# 	rules: [
# 		{ token: '', foreground: 'D4D4D4', background: '1E1E1E' },
# 		{ token: 'invalid', foreground: 'f44747' },
# 		{ token: 'emphasis', fontStyle: 'italic' },
# 		{ token: 'strong', fontStyle: 'bold' },

# 		{ token: 'variable', foreground: '74B0DF' },
# 		{ token: 'variable.predefined', foreground: '4864AA' },
# 		{ token: 'variable.parameter', foreground: '9CDCFE' },
# 		{ token: 'constant', foreground: '569CD6' },
# 		{ token: 'comment', foreground: '608B4E' },
# 		{ token: 'number', foreground: 'B5CEA8' },
# 		{ token: 'number.hex', foreground: '5BB498' },
# 		{ token: 'regexp', foreground: 'B46695' },
# 		{ token: 'annotation', foreground: 'cc6666' },
# 		{ token: 'type', foreground: '3DC9B0' },

# 		{ token: 'delimiter', foreground: 'DCDCDC' },
# 		{ token: 'delimiter.html', foreground: '808080' },
# 		{ token: 'delimiter.xml', foreground: '808080' },

# 		{ token: 'tag', foreground: '569CD6' },
# 		{ token: 'tag.id.pug', foreground: '4F76AC' },
# 		{ token: 'tag.class.pug', foreground: '4F76AC' },
# 		{ token: 'meta.scss', foreground: 'A79873' },
# 		{ token: 'meta.tag', foreground: 'CE9178' },
# 		{ token: 'metatag', foreground: 'DD6A6F' },
# 		{ token: 'metatag.content.html', foreground: '9CDCFE' },
# 		{ token: 'metatag.html', foreground: '569CD6' },
# 		{ token: 'metatag.xml', foreground: '569CD6' },
# 		{ token: 'metatag.php', fontStyle: 'bold' },

# 		{ token: 'key', foreground: '9CDCFE' },
# 		{ token: 'string.key.json', foreground: '9CDCFE' },
# 		{ token: 'string.value.json', foreground: 'CE9178' },

# 		{ token: 'attribute.name', foreground: '9CDCFE' },
# 		{ token: 'attribute.value', foreground: 'CE9178' },
# 		{ token: 'attribute.value.number.css', foreground: 'B5CEA8' },
# 		{ token: 'attribute.value.unit.css', foreground: 'B5CEA8' },
# 		{ token: 'attribute.value.hex.css', foreground: 'D4D4D4' },

# 		{ token: 'string', foreground: 'CE9178' },
# 		{ token: 'string.sql', foreground: 'FF0000' },

# 		{ token: 'keyword', foreground: '569CD6' },
# 		{ token: 'keyword.flow', foreground: 'C586C0' },
# 		{ token: 'keyword.json', foreground: 'CE9178' },
# 		{ token: 'keyword.flow.scss', foreground: '569CD6' },

# 		{ token: 'operator.scss', foreground: '909090' },
# 		{ token: 'operator.sql', foreground: '778899' },
# 		{ token: 'operator.swift', foreground: '909090' },
# 		{ token: 'predefined.sql', foreground: 'FF00FF' },
# 	],
# 	colors: {
# 		[editorBackground]: '#1E1E1E',
# 		[editorForeground]: '#D4D4D4',
# 		[editorInactiveSelection]: '#3A3D41',
# 		[editorIndentGuides]: '#404040',
# 		[editorActiveIndentGuides]: '#707070',
# 		[editorSelectionHighlight]: '#ADD6FF26'
# 	}
# };

# {
# 	base: 'vs',
# 	inherit: false,
# 	rules: [
# 		{ token: '', foreground: '000000', background: 'fffffe' },
# 		{ token: 'invalid', foreground: 'cd3131' },
# 		{ token: 'emphasis', fontStyle: 'italic' },
# 		{ token: 'strong', fontStyle: 'bold' },

# 		{ token: 'variable', foreground: '001188' },
# 		{ token: 'variable.predefined', foreground: '4864AA' },
# 		{ token: 'constant', foreground: 'dd0000' },
# 		{ token: 'comment', foreground: '008000' },
# 		{ token: 'number', foreground: '098658' },
# 		{ token: 'number.hex', foreground: '3030c0' },
# 		{ token: 'regexp', foreground: '800000' },
# 		{ token: 'annotation', foreground: '808080' },
# 		{ token: 'type', foreground: '008080' },

# 		{ token: 'delimiter', foreground: '000000' },
# 		{ token: 'delimiter.html', foreground: '383838' },
# 		{ token: 'delimiter.xml', foreground: '0000FF' },

# 		{ token: 'tag', foreground: '800000' },
# 		{ token: 'tag.id.pug', foreground: '4F76AC' },
# 		{ token: 'tag.class.pug', foreground: '4F76AC' },
# 		{ token: 'meta.scss', foreground: '800000' },
# 		{ token: 'metatag', foreground: 'e00000' },
# 		{ token: 'metatag.content.html', foreground: 'FF0000' },
# 		{ token: 'metatag.html', foreground: '808080' },
# 		{ token: 'metatag.xml', foreground: '808080' },
# 		{ token: 'metatag.php', fontStyle: 'bold' },

# 		{ token: 'key', foreground: '863B00' },
# 		{ token: 'string.key.json', foreground: 'A31515' },
# 		{ token: 'string.value.json', foreground: '0451A5' },

# 		{ token: 'attribute.name', foreground: 'FF0000' },
# 		{ token: 'attribute.value', foreground: '0451A5' },
# 		{ token: 'attribute.value.number', foreground: '098658' },
# 		{ token: 'attribute.value.unit', foreground: '098658' },
# 		{ token: 'attribute.value.html', foreground: '0000FF' },
# 		{ token: 'attribute.value.xml', foreground: '0000FF' },

# 		{ token: 'string', foreground: 'A31515' },
# 		{ token: 'string.html', foreground: '0000FF' },
# 		{ token: 'string.sql', foreground: 'FF0000' },
# 		{ token: 'string.yaml', foreground: '0451A5' },

# 		{ token: 'keyword', foreground: '0000FF' },
# 		{ token: 'keyword.json', foreground: '0451A5' },
# 		{ token: 'keyword.flow', foreground: 'AF00DB' },
# 		{ token: 'keyword.flow.scss', foreground: '0000FF' },

# 		{ token: 'operator.scss', foreground: '666666' },
# 		{ token: 'operator.sql', foreground: '778899' },
# 		{ token: 'operator.swift', foreground: '666666' },
# 		{ token: 'predefined.sql', foreground: 'C700C7' },
# 	],
# 	colors: {
# 		[editorBackground]: '#FFFFFE',
# 		[editorForeground]: '#000000',
# 		[editorInactiveSelection]: '#E5EBF1',
# 		[editorIndentGuides]: '#D3D3D3',
# 		[editorActiveIndentGuides]: '#939393',
# 		[editorSelectionHighlight]: '#ADD6FF4D'
# 	}
# }
