package jasko.tim.lisp.editors;

import jasko.tim.lisp.LispPlugin;
import jasko.tim.lisp.swank.SwankInterface;
import jasko.tim.lisp.util.LispUtil;

import org.eclipse.jface.text.IDocument;
import org.eclipse.jface.text.IRegion;
import org.eclipse.jface.text.ITextViewer;
import org.eclipse.jface.text.Region;
import org.eclipse.jface.text.hyperlink.IHyperlinkDetector;
import org.eclipse.jface.text.hyperlink.IHyperlink;

public class LispHyperlinkDetector implements IHyperlinkDetector {
	String prev = ")"; // impossible value
	boolean haveDefinition = false;
	LispEditor editor;
	
	private static final int TIMEOUT = 2000;

	public LispHyperlinkDetector() {
	}
	
	public LispHyperlinkDetector(LispEditor edt) {
		editor = edt;
	}
	
	public LispHyperlinkDetector(ITextViewer textViewer) {
	}
	
	public IHyperlink[] detectHyperlinks(ITextViewer textViewer, IRegion region, 
			boolean canShowMultipleHyperlinks) {
		if (region == null || textViewer == null)
			return null;

		IDocument doc = textViewer.getDocument();

		int offset= region.getOffset();
		
		if (doc == null) return null;

		int[] range = LispUtil.getCurrentFullWordRange(doc, offset);
		
		String function = LispUtil.getCurrentFullWord(doc, offset);
		
		if (function.equals("")) {
			return null;
		}
		
		Region reg = new Region(range[0], range[1]);
		if (!function.equals(prev)) {
			prev = function;
			
			for( String keyword : LispSpecialWordDetector.RESERVED_WORDS ) {
				if ( function.equalsIgnoreCase(keyword) ){
					haveDefinition = false;
					return null;
				}
			}
			
			if( function.charAt(0) == '\"' ){ //don't call swank for strings
				haveDefinition = false; 
			}
			else {
				SwankInterface swank = LispPlugin.getDefault().getSwank();
				haveDefinition = swank.haveDefinitions(function, 
						LispUtil.getPackage(doc.get()+"\n",range[0]), TIMEOUT);
			}
		}
		if( haveDefinition ) {
			return new IHyperlink[] {new LispHyperlink(editor, reg, function)};
		}
		else {
			return null;
		}
	}
}
