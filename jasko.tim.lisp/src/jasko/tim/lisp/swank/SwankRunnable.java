package jasko.tim.lisp.swank;

/**
 * Commands sent to Swank are associated with an instance of some descendant of this class.
 * The result of that command will be stuck in to the result member of the class,
 *  and then SwankInterface will <i>attempt</i> to clone the SwnakRunnable via the
 *  clone method. It should be noted that this tends to fail with anonymous classes,
 *  so don't use those where certain threading issues are a concern.
 * The SwankRunnable will then be run in the main GUI thread, thus avoiding
 *  the many multithreading issues we would otherwise face.
 * 
 * @see SwankInterface
 * @author Tim Jasko
 *
 */
public abstract class SwankRunnable implements Runnable {
	public LispNode result;
	
	public SwankRunnable clone() {
		SwankRunnable ret;
		try {
			ret = this.getClass().newInstance();
			ret.result = result;
			
			return ret;
		} catch (InstantiationException e) {
		} catch (IllegalAccessException e) {
		}
		
		return this;
	}
}
