/**
	Contains interfaces and enums for evented I/O drivers.

	Copyright: © 2012 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.task;

import vibe.core.sync;
import vibe.utils.array;

import core.thread;
import std.exception;
import std.traits;
import std.typecons;
import std.variant;


/** Represents a single task as started using vibe.core.runTask.

	All methods of TaskFiber are also available as methods of Task.
*/
struct Task {
	private {
		TaskFiber m_fiber;
		size_t m_taskCounter;
	}

	private this(TaskFiber fiber, size_t task_counter)
	{
		m_fiber = fiber;
		m_taskCounter = task_counter;
	}

	/// Makes all methods of TaskFiber available for Task.
	alias fiber this;

	/** Returns the Task instance belonging to the calling task.
	*/
	static Task getThis()
	{
		auto fiber = Fiber.getThis();
		if( !fiber ) return Task(null, 0);
		auto tfiber = cast(TaskFiber)fiber;
		assert(tfiber !is null, "Invalid or null fiber used to construct Task handle.");
		return Task(tfiber, tfiber.m_taskCounter);
	}

	nothrow:
	@property inout(TaskFiber) fiber() inout { return m_fiber; }
	@property inout(Thread) thread() inout { if( m_fiber ) return m_fiber.thread; return null; }

	/** Determines if the task is still running.
	*/
	@property bool running()
	const {
		assert(m_fiber, "Invalid task handle");
		try if( m_fiber.state == Fiber.State.TERM ) return false; catch {}
		return m_fiber.m_running && m_fiber.m_taskCounter == m_taskCounter;
	}

	bool opEquals(in ref Task other) const { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
	bool opEquals(in Task other) const { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
}



/** The base class for a task aka Fiber.

	This class represents a single task that is executed concurrencly
	with other tasks. Each task is owned by a single thread.
*/
class TaskFiber : Fiber {
	private {
		Thread m_thread;
		Variant[string] m_taskLocalStorage;
		MessageQueue m_messageQueue;
	}

	protected {
		size_t m_taskCounter;
		bool m_running;
	}

	protected this(void delegate() fun, size_t stack_size)
	{
		super(fun, stack_size);
		m_thread = Thread.getThis();
		m_messageQueue = new MessageQueue;
	}

	/** Returns the thread that owns this task.
	*/
	@property inout(Thread) thread() inout nothrow { return m_thread; }

	/** Returns the handle of the current Task running on this fiber.
	*/
	@property Task task() { return Task(this, m_taskCounter); }

	@property inout(MessageQueue) messageQueue() inout { return m_messageQueue; }

	/** Blocks until the task has ended.
	*/
	abstract void join();

	/** Throws an InterruptExeption within the task as soon as it calls a blocking function.
	*/
	abstract void interrupt();

	/** Terminates the task without notice as soon as it calls a blocking function.
	*/
	abstract void terminate();

	/** Sets a task local variable.
	*/
	void set(T)(string name, T value)
	{
		m_taskLocalStorage[name] = Variant(value);
	}

	/** Returns a task local variable.
	*/
	T get(T)(string name)
	{
		Variant* pvar;
		pvar = name in m_taskLocalStorage;
		enforce(pvar !is null, "Accessing unset TLS variable '"~name~"'.");
		return pvar.get!T();
	}

	/** Determines if a certain task local variable is set.
	*/
	bool isSet(string name)
	{
		return (name in m_taskLocalStorage) !is null;
	}

	/** Clears all task local variables.
	*/
	protected void resetLocalStorage()
	{
		m_taskLocalStorage = null;
	}
}


/** Exception that is thrown by Task.interrupt.
*/
class InterruptException : Exception {
	this()
	{
		super("Task interrupted.");
	}
}

private class MessageQueue {
	private {
		TaskMutex m_mutex;
		TaskCondition m_condition;
		FixedRingBuffer!Variant m_queue;
		FixedRingBuffer!Variant m_priorityQueue;
	}

	this()
	{
		m_mutex = new TaskMutex;
		m_condition = new TaskCondition(m_mutex);
		m_queue.capacity = 32;
		m_priorityQueue.capacity = 32;
	}

	void clear()
	{
		synchronized(m_mutex){
			m_queue.clear();
			m_priorityQueue.clear();
		}
		m_condition.notifyAll();
	}

	void send(Variant msg)
	{
		synchronized(m_mutex){
			m_queue.put(msg);
		}
		m_condition.notify();
	}

	void prioritySend(Variant msg)
	{
		synchronized(m_mutex){
			m_priorityQueue.put(msg);
		}
		m_condition.notify();
	}

	void receive(OPS...)(OPS ops)
	{
		synchronized(m_mutex){
			while(true){
				import vibe.core.log;
				logTrace("looking for messages");
				if( receiveQueue(m_priorityQueue, ops) ) return;
				if( receiveQueue(m_queue, ops) ) return;
				logTrace("received no message, waiting..");
				m_condition.wait();
			}
		}
	}

	void receiveTimeout(OPS...)(Duration timeout, OPS ops)
	{
		auto limit_time = Clock.currTime();
		synchronized(m_mutex){
			while(true){
				if( receiveQueue(m_priorityQueue, ops) ) return true;
				if( receiveQueue(m_queue, ops) ) return true;
				auto now = Clock.currTime();
				if( now > limit_time ) return false;
				m_condition.wait(limit_time - now);
			}
		}
		return false;
	}

	private static bool receiveQueue(OPS...)(ref FixedRingBuffer!Variant queue, OPS ops)
	{
		auto r = queue[];
		while(!r.empty){
			scope(failure) queue.removeAt(r);
			auto msg = r.front;
			bool matched;
			foreach(i, TO; OPS){
				alias ParameterTypeTuple!TO ArgTypes;

				static if( ArgTypes.length == 1 ){
					static if( is(ArgTypes[0] == Variant) )
						matched = callOp(ops[i], msg);
					else if( msg.convertsTo!(ArgTypes[0]) )
						matched = callOp(ops[i], msg.get!(ArgTypes[0]));
				} else if( msg.convertsTo!(Tuple!ArgTypes) ){
					matched = callOp(ops[i], msg.get!(Tuple!ArgTypes).expand);
				}
				if( matched ) break;
			}
			if( matched ){
				queue.removeAt(r);
				return true;
			}
			r.popFront();
		}
		return false;
	}

	private static bool callOp(OP, ARGS...)(OP op, ARGS args)
	{
		static if( is(ReturnType!op == bool) ){
			return op(args);
		} else {
			op(args);
			return true;
		}
	}
}
