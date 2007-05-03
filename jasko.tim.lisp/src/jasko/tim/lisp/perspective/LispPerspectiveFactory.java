package jasko.tim.lisp.perspective;

import jasko.tim.lisp.inspector.InspectorView;
import jasko.tim.lisp.navigator.LispNavigator;
import jasko.tim.lisp.views.*;
import jasko.tim.lisp.wizards.*;

import org.eclipse.ui.*;


public class LispPerspectiveFactory implements IPerspectiveFactory {

	public void createInitialLayout(IPageLayout layout) {
		//	 Get the editor area.
		String editorArea = layout.getEditorArea();
		
		// Top left: Resource Navigator view
		IFolderLayout topLeft = layout.createFolder("topLeft", IPageLayout.LEFT, 0.25f,
			editorArea);
		topLeft.addView(LispNavigator.ID);

		// Bottom left: Outline view and Property Sheet view
		IFolderLayout bottomLeft = layout.createFolder("bottomLeft", IPageLayout.BOTTOM, 0.60f,
			"topLeft");
		bottomLeft.addView(IPageLayout.ID_OUTLINE);

		// Bottom right: Task List view
		IFolderLayout bottom = layout.createFolder("bottom", IPageLayout.BOTTOM, 0.60f, editorArea);
		bottom.addView(ReplView.ID);
		bottom.addView(IPageLayout.ID_PROBLEM_VIEW);
		bottom.addView(AproposView.ID);
		bottom.addView(ThreadView.ID);
		bottom.addView(InspectorView.ID);
		
		layout.addShowViewShortcut(ReplView.ID);
		layout.addShowViewShortcut(IPageLayout.ID_PROBLEM_VIEW);
		layout.addShowViewShortcut(AproposView.ID);
		layout.addShowViewShortcut(ThreadView.ID);
		layout.addShowViewShortcut(InspectorView.ID);
		layout.addShowViewShortcut(SecondaryReplView.ID);
		layout.addShowViewShortcut(IPageLayout.ID_OUTLINE);
		
		layout.addNewWizardShortcut(NewLispFileWizard.ID);
		layout.addNewWizardShortcut(NewProjectWiz.ID);
	}

}
