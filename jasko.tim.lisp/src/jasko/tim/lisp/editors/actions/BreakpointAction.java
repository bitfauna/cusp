package jasko.tim.lisp.editors.actions;

import jasko.tim.lisp.editors.ILispEditor;

import org.eclipse.jface.action.IAction;
import org.eclipse.jface.text.*;
import org.eclipse.ui.IEditorPart;


public class BreakpointAction extends LispAction {
    private ILispEditor editor;
    private static String start = "(progn #|br|# (break) ";
    private static String end = ")";
    
    public BreakpointAction () {}
    
    public BreakpointAction (ILispEditor editor) {
        this.editor = editor;
    }
    
    public void setActiveEditor(IAction action, IEditorPart targetEditor) {
        editor = (ILispEditor)targetEditor;
    }
    
    public void run () {
        ITextSelection ts = 
        	(ITextSelection) editor.getSelectionProvider().getSelection();
        int offset = ts.getOffset();
        IDocument doc = editor.getDocument();
        
        if( ts.getLength() > 0 ){
        	String oldtxt = ts.getText();
        	String txt = "";
        	if( oldtxt.length() > start.length() + end.length()
        			&& oldtxt.startsWith(start) && oldtxt.endsWith(end) ){
        		txt = oldtxt.substring(start.length(), oldtxt.length()-end.length());
        	} else {
            	txt = start + oldtxt + end;        		
        	}
        	try{
        		doc.replace(offset, ts.getLength(), txt);
        		editor.getSelectionProvider()
        		  .setSelection(new TextSelection(doc,offset,txt.length()));
        	}
        	catch (BadLocationException e){
                e.printStackTrace();        		
        	}
        }
    }
}
