package jasko.tim.lisp.builder;

import jasko.tim.lisp.LispPlugin;
import jasko.tim.lisp.swank.LispNode;
import jasko.tim.lisp.swank.LispParser;
import jasko.tim.lisp.swank.SwankInterface;
import jasko.tim.lisp.editors.actions.FileCompiler;
import jasko.tim.lisp.util.LispUtil;


import java.io.*;
import java.util.HashMap;
import java.util.Map;
import java.util.ArrayList;


import org.eclipse.core.resources.*;
import org.eclipse.core.runtime.*;
import org.eclipse.ui.texteditor.MarkerUtilities;

public class LispBuilder extends IncrementalProjectBuilder {

	public static final String BUILDER_ID = "jasko.tim.lisp.lispBuilder";
	public static final String MARKER_TYPE = "jasko.tim.lisp.lispProblem";
	public static final String TASK_MARKER_TYPE = "jasko.tim.lisp.lispTask";
	

	class SampleDeltaVisitor implements IResourceDeltaVisitor {

		public boolean visit(IResourceDelta delta) throws CoreException {
			IResource resource = delta.getResource();
			switch (delta.getKind()) {
			case IResourceDelta.ADDED:
				// handle added resource
				checkLisp(resource);
				break;
			case IResourceDelta.REMOVED:
				// handle removed resource
				break;
			case IResourceDelta.CHANGED:
				// handle changed resource
				checkLisp(resource);
				break;
			}
			//return true to continue visiting children.
			return true;
		}
	}

	class SampleResourceVisitor implements IResourceVisitor {
		public boolean visit(IResource resource) {
			if (resource.isAccessible()){ 
				checkLisp(resource);
				//return true to continue visiting children.
				return true;
			} else {
				return false;
			}
		}
	}


	public static void addMarker(IFile file, String message, int lineNumber,
			int severity) {
		try {
			IMarker marker = file.createMarker(MARKER_TYPE);
			//marker.setAttribute(IMarker.CHAR_START, charOffset);
			//marker.setAttribute(IMarker.CHAR_END, charOffset + 1);
			marker.setAttribute(IMarker.MESSAGE, message);
			marker.setAttribute(IMarker.SEVERITY, severity);
			if (lineNumber == -1) {
				lineNumber = 1;
			}
			marker.setAttribute(IMarker.LINE_NUMBER, lineNumber);
		} catch (CoreException e) {
			e.printStackTrace();
		}
	}
	
	protected IProject[] build(int kind, Map args, IProgressMonitor monitor)
			throws CoreException {
		if (kind == FULL_BUILD) {
			fullBuild(monitor);
		} else {
			IResourceDelta delta = getDelta(getProject());
			if (delta == null) {
				fullBuild(monitor);
			} else {
				incrementalBuild(delta, monitor);
			}
		}
		return null;
	}

	
	private void addBadPackageMarker(IFile file, int offsetStart, int offsetEnd, String pkg){
		Map<String, Object> attr = new HashMap<String, Object>();
		attr.put(IMarker.CHAR_START, offsetStart);
		attr.put(IMarker.CHAR_END, offsetEnd);
		
		attr.put(IMarker.MESSAGE, "Package "+ pkg + " is not loaded");
		attr.put(IMarker.SEVERITY, IMarker.SEVERITY_ERROR);
		try {
			MarkerUtilities.createMarker(file, attr, MARKER_TYPE);			
		} catch (Exception e) {
			e.printStackTrace();
		}
	}
	
	void checkLisp(IResource resource) {
		if (resource instanceof IFile && 
				(resource.getName().endsWith(".lisp") || resource.getName().endsWith(".el")
						|| resource.getName().endsWith(".cl"))) {
			
			try {
				IFile file = (IFile) resource;
				deleteMarkers(file);
				System.out.println("*builder");
				BufferedReader reader = new BufferedReader(
						new InputStreamReader(file.getContents()));
				StringBuilder sb = new StringBuilder();
				String line = reader.readLine();
				int numLines = 0;
				while (line != null) {
					sb.append(line);
					sb.append('\n');
					line = reader.readLine();
					++numLines;
				}
				LispParser parser = new LispParser();
				LispNode code = parser.parseCode(sb.toString());
				boolean cancompile = true;
				// check parens
				System.out.println("*parens:" + parser.parenBalance);
				if (parser.parenBalance > 0) {
					addMarker(file, parser.parenBalance + " more closing parentheses needed.",
							numLines, IMarker.SEVERITY_ERROR);
				} else if (parser.parenBalance < 0) {
					addMarker(file, -parser.parenBalance + " more opening parentheses needed.",
							numLines, IMarker.SEVERITY_ERROR);
				}

				// check if package dependence is satisfied: (TODO: need to add this also to FileCompiler, refactor this all!)
				ArrayList<String> pkgs = LispPlugin.getDefault().getSwank().getAvailablePackages(2000);
				for( LispNode node: code.params ){
					String nodetype = node.car().value.toLowerCase();
					// == defpackage
					if( nodetype.equals("defpackage") ){
						pkgs.add(LispUtil.formatPackage(node.cadr().value));
						for( LispNode subnode: node.params){
							String subtype = subnode.car().value.toLowerCase();
							//process nicknames
							if(subtype.equals(":nicknames")){
								for(int i = 1; i < subnode.params.size(); ++i){
									pkgs.add(LispUtil.formatPackage(subnode.get(i).value));
								}
							//process :use	
							} else if (subtype.equals(":use")) {
								for(int i = 1; i < subnode.params.size(); ++i){
									LispNode usepkg = subnode.params.get(i);
									if(!pkgs.contains(LispUtil.formatPackage(usepkg.value))){
										addBadPackageMarker(file,usepkg.offset,
												usepkg.endOffset+1,
												LispUtil.formatPackage(usepkg.value));
										cancompile = false;
									}									
								}
							//process :shadowing-import-from and :import-from dependence	
							} else if (subtype.equals(":shadowing-import-from") ||
									    subtype.equals(":import-from")) {
								LispNode usepkg = subnode.cadr();
								if(!pkgs.contains(LispUtil.formatPackage(usepkg.value))){
									if (usepkg.offset == 0) {
										addBadPackageMarker(file,subnode.offset,
												subnode.offset + subtype.length(),
												LispUtil.formatPackage(usepkg.value));										
									} else {
										addBadPackageMarker(file,usepkg.offset,
												usepkg.endOffset,
												LispUtil.formatPackage(usepkg.value));										
									}
									cancompile = false;
								}
							}
						}
					// == make-package
					} else if (nodetype.equals("make-package")) {
						pkgs.add(LispUtil.formatPackage(node.cadr().value));
						LispNode nicks = node.getf(":nicknames");
						if(nicks != null){
							for(LispNode nick: nicks.params){
								pkgs.add(LispUtil.formatPackage(nick.value));
							}
						}
						LispNode uses = node.getf(":use");
						if(uses != null){
							for(LispNode usepkg: uses.params){
								if(!pkgs.contains(LispUtil.formatPackage(usepkg.value))){
									if (usepkg.offset == 0) {
										addBadPackageMarker(file,node.offset,
												node.offset + nodetype.length(),
												LispUtil.formatPackage(usepkg.value));										
									} else {
										addBadPackageMarker(file,usepkg.offset,
												usepkg.endOffset,
												LispUtil.formatPackage(usepkg.value));										
									}
									cancompile = false;									
								}
							}
						}
					} else if (nodetype.equals("in-package")){
						LispNode pkgnode = node.cadr();
						if(!pkgs.contains(LispUtil.formatPackage(pkgnode.value))){
							if (pkgnode.offset == 0) {
								addBadPackageMarker(file,node.offset,
										node.offset + nodetype.length(),
										LispUtil.formatPackage(pkgnode.value));										
							} else {
								addBadPackageMarker(file,pkgnode.offset,
										pkgnode.endOffset,
										LispUtil.formatPackage(pkgnode.value));										
							}
							cancompile = false;							
						}
					}
				}

				
				if (cancompile) {
					//compile file
					SwankInterface swank = LispPlugin.getDefault().getSwank();
					swank.sendCompileFile(file.getLocation().toString(), 
							new FileCompiler.CompileListener(file));
					System.out.printf("Compiling %s\n", file.getLocation().toString());
				}
			} catch (Exception e) {
				e.printStackTrace();
			}
			/*
				int open = 0;
				int close = 0;
				int lineNum = 1;
				int charOffset = 0;
				
				BufferedReader reader = new BufferedReader(
						new InputStreamReader(file.getContents()));
				
				String line = reader.readLine();
				boolean inQuotes = false;
				boolean inComment = false;
				while (line != null) {
					for (int i=0; i<line.length(); ++i) {
						if (inComment) {
							int endComment = line.indexOf("|#", i);
							if (endComment >= 0) {
								charOffset += endComment - i;
								i = endComment;
								inComment = false;
							} else {
								break;
							}
						}
						char c = line.charAt(i);
						if (c == '(' && !inQuotes) {
							++open;
						} else if (c == ')' && !inQuotes) {
							++close;
							if (close > open) {
								// reset everything so we don't throw off the rest of the matching
								close = open;
								addMarker(file, "Unmatched closing parenthesis.",
										lineNum, charOffset, IMarker.SEVERITY_ERROR);
							} // if
						} else if (c == ';' && !inQuotes) {
							i = line.length();
							break;
						} else if (c == '"') {
							if (inQuotes) {
								inQuotes = false;
							} else {
								inQuotes = true;
							}
						} else if (c == '#') {
							if (i+1 < line.length()) {
								if (line.charAt(i+1) == '|') {
									inComment = true;
								}
							}
						}
						++charOffset;
					} // for i
					
					++lineNum;
					line = reader.readLine();
					++charOffset;
				} // while
				if (open > close) {
					addMarker(file, (open-close) + " more closing parentheses needed.",
							lineNum-1,charOffset, IMarker.SEVERITY_ERROR);
				}
			} catch (CoreException e) {
				e.printStackTrace();
			} catch (IOException e) {
				e.printStackTrace();
			}*/
		}
	}

	private void deleteMarkers(IFile file) {
		try {
			file.deleteMarkers(MARKER_TYPE, false, IResource.DEPTH_ZERO);
			//file.deleteMarkers(null, false, IResource.DEPTH_ZERO);
		} catch (CoreException ce) {
		}
	}

	protected void fullBuild(final IProgressMonitor monitor)
			throws CoreException {
		try {
			getProject().accept(new SampleResourceVisitor());
		} catch (CoreException e) {
		}
	}


	protected void incrementalBuild(IResourceDelta delta,
			IProgressMonitor monitor) throws CoreException {
		// the visitor does the work.
		delta.accept(new SampleDeltaVisitor());
	}
}
