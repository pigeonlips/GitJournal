import 'package:flutter/material.dart';

import 'package:gitjournal/core/notes_folder_fs.dart';
import 'package:gitjournal/editors/common.dart';
import 'package:gitjournal/settings.dart';

class EditorScaffold extends StatefulWidget {
  final Editor editor;
  final EditorState editorState;
  final bool noteModified;
  final IconButton extraButton;
  final Widget body;
  final NotesFolderFS parentFolder;
  final bool allowEdits;

  EditorScaffold({
    @required this.editor,
    @required this.editorState,
    @required this.noteModified,
    @required this.body,
    @required this.parentFolder,
    this.extraButton,
    this.allowEdits = true,
  });

  @override
  _EditorScaffoldState createState() => _EditorScaffoldState();
}

class _EditorScaffoldState extends State<EditorScaffold> {
  var hideUIElements = false;

  @override
  void initState() {
    super.initState();

    hideUIElements = Settings.instance.zenMode;
    widget.editorState.addListener(_editorChanged);
  }

  @override
  void dispose() {
    widget.editorState.removeListener(_editorChanged);

    super.dispose();
  }

  void _editorChanged() {
    if (Settings.instance.zenMode && !hideUIElements) {
      setState(() {
        hideUIElements = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            opacity: hideUIElements ? 0.0 : 1.0,
            child: EditorAppBar(
              editor: widget.editor,
              editorState: widget.editorState,
              noteModified: widget.noteModified,
              extraButton: widget.extraButton,
            ),
          ),
          Expanded(
            child: GestureDetector(
              child: widget.body,
              onTap: () {
                if (Settings.instance.zenMode) {
                  setState(() {
                    hideUIElements = false;
                  });
                }
              },
              behavior: HitTestBehavior.translucent,
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            opacity: hideUIElements ? 0.0 : 1.0,
            child: EditorBottomBar(
              editor: widget.editor,
              editorState: widget.editorState,
              parentFolder: widget.parentFolder,
              allowEdits: widget.allowEdits,
              zenMode: Settings.instance.zenMode,
              onZenModeChanged: () {
                setState(() {
                  Settings.instance.zenMode = !Settings.instance.zenMode;
                  Settings.instance.save();

                  if (Settings.instance.zenMode) {
                    hideUIElements = true;
                  }
                });
              },
            ),
          )
        ],
      ),
    );
  }
}