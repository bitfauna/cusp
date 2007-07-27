package jasko.tim.lisp.util;

public class TopLevelItem implements Comparable<TopLevelItem> {
	public String name;
	public int offset;
	public int offsetEnd;
	public int nameOffset;
	public String type;
	public String pkg;
	
	public int compareTo(TopLevelItem o) {
		return name.toLowerCase().compareTo( 
			o.name.toLowerCase() );
	}
	
	public String toString(){
		return "{"+type+","+name+" ("+offset+")}";
	}
}
