package jasko.tim.lisp.editors.actions;

import jasko.tim.lisp.editors.ILispEditor;
import jasko.tim.lisp.swank.*;

public class ProfileFunctionAction extends LispAction {
	public static final String ID = "jasko.tim.lisp.actions.ProfileFunctionAction";
	
	public ProfileFunctionAction() {
	}
	
	public ProfileFunctionAction(ILispEditor editor) {
		super(editor);
	}

	
	public void run() {
		String symbol = getSymbol();
		
		if (!symbol.equals("")) {
			getSwank().sendToggleProfileFunction(symbol, getPackage(), new SwankRunnable() {
				public void run() {
					editor.showMessage(result.getf(":return").getf(":ok").value);
				}
			});
		}
	}
}
