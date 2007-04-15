package jasko.tim.lisp.editors.actions;

import jasko.tim.lisp.*;
import jasko.tim.lisp.editors.LispEditor;
import jasko.tim.lisp.swank.*;

import org.eclipse.jface.dialogs.*;


public class UndefineFunctionAction extends LispAction {
	
	public UndefineFunctionAction() {
	}
	
	public UndefineFunctionAction(LispEditor editor) {
		super(editor);
	}
	
	public void run() {
		String symbol = getSymbol();
		SwankInterface swank = LispPlugin.getDefault().getSwank();
		
		InputDialog win = new InputDialog(editor.getSite().getShell(), "Undefine",
				"Undefine the following symbol:", symbol, new IInputValidator() {
			public String isValid(String newText) {
				if (newText.equals("")) {
					return "Symbol may not be blank.";
				}
				
				return null;
			}
		});
		
		if (win.open() == InputDialog.OK && !win.getValue().equals("")) {
			swank.sendUndefine(win.getValue(), editor.getPackage(), null);
		}
	}

}
