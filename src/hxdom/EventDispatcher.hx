/****
* Copyright (C) 2013 Sam MacPherson
* 
* Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
* 
* The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
* 
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
****/

package hxdom;

import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import hxdom.EventDispatcher.EventHandler;

using Lambda;

/**
 * A representation of an arbitrary function split into two serializable components.
 */
typedef EventHandler = {
	inst:Dynamic,
	func:String
};

/**
 * Cross-platform event dispatcher with the ability to be serialized.
 * 
 * @author Sam MacPherson
 */
class EventDispatcher implements IEventDispatcher {
	
	macro public function addEventListener (ethis:Expr, type:ExprOf<String>, listener:ExprOf<hxdom.html.EventListener>, ?useCapture:ExprOf<Bool>):ExprOf<Void> {
		return macro $ethis.__addEventListener($type, ${EventDispatcherMacro.splitFunction(listener)}, $useCapture);
	}

	macro public function removeEventListener (ethis:Expr, type:ExprOf<String>, listener:ExprOf<hxdom.html.EventListener>, ?useCapture:ExprOf<Bool>):ExprOf<Void> {
		return macro $ethis.__removeEventListener($type, ${EventDispatcherMacro.splitFunction(listener)}, $useCapture);
	}

	macro public static function make (listener:ExprOf<hxdom.html.EventListener>):ExprOf<EventHandler> {
		return EventDispatcherMacro.splitFunction(listener);
	}
	
}

#if !macro
@:build(hxdom.EventDispatcherMacro.store())
@:autoBuild(hxdom.EventDispatcherMacro.build())
#end
interface IEventDispatcher {
	
	#if !macro
	@:skip var __listeners:Map<String, List<{handler:EventHandler, cap:Bool}>>;
	
	public function __addEventListener (type:String, handler:EventHandler, ?useCapture:Bool = false):Void {
		if (__listeners == null) __listeners = new Map<String, List<{handler:EventHandler, cap:Bool}>>();
		
		var list = __listeners.get(type);
		var obj = { handler:handler, cap:useCapture };
		if (list == null) {
			list = new List<{handler:EventHandler, cap:Bool}>();
			list.add(obj);
			__listeners.set(type, list);
		} else {
			for (i in list) {
				if (i.handler.inst == handler.inst && i.handler.func == handler.func && i.cap == useCapture) return;
			}
			list.add(obj);
		}
	}
	
	public function __removeEventListener (type:String, handler:EventHandler, ?useCapture:Bool = false):Void {
		if (__listeners == null || !__listeners.exists(type)) return;
		
		var list = __listeners.get(type);
		for (i in list) {
			if (i.handler.inst == handler.inst && i.handler.func == handler.func && i.cap == useCapture) {
				list.remove(i);
			}
		}
	}

	public function dispatchEvent (event:hxdom.html.Event):Bool {
		if (__listeners == null) __listeners = new Map<String, List<{handler:EventHandler, cap:Bool}>>();
		
		var list = __listeners.get(event.type);
		if (list != null) {
			for (i in list) {
				Reflect.callMethod(i.handler.inst, Reflect.field(i.handler.inst, i.handler.func), [event]);
			}
		}
		
		return !event.defaultPrevented;
	}
	#end
	
}

class EventDispatcherMacro {
	
	#if macro
	static var edFields:Array<Field> = new Array<Field>();
	
	/**
	 * Check through full inheritance chain to find the method.
	 */
	static function hasMethod (cls:ClassType, name:String):Bool {
		while (cls != null) {
			for (i in cls.fields.get()) {
				if (i.name == name) {
					return true;
				}
			}
			
			if (cls.superClass == null) break;
			
			cls = cls.superClass.t.get();
		}
		
		return false;
	}
	
	/**
	 * Check if this class has a static function with the given name.
	 */
	static function hasStaticFunction (cls:ClassType, name:String):Bool {
		for (i in cls.statics.get()) {
			if (i.name == name) {
				return true;
			}
		}
		
		return false;
	}
	
	/**
	 * Build a fully qualified class name reference.
	 */
	static function getFullClassName (cls:ClassType):Expr {
		if (cls.pack.length > 0) {
			var expr = { expr:EConst(CIdent(cls.pack[0])), pos:Context.currentPos() };
			for (i in 1 ... cls.pack.length) {
				expr = { expr:EField(expr, cls.pack[i]), pos:Context.currentPos() };
			}
			expr = { expr:EField(expr, cls.name), pos:Context.currentPos() };
			return expr;
		} else {
			return { expr:EConst(CIdent(cls.name)), pos:Context.currentPos() };
		}
	}
	
	/**
	 * Split a function reference into an instance and a function name so it can be serialized.
	 */
	public static function splitFunction (listener:ExprOf<hxdom.html.EventListener>):ExprOf<EventHandler> {
		var split = null;
		switch (listener.expr) {
			case EField(e, f):
				split = { inst: e, func:{expr:EConst(CString(f)), pos:Context.currentPos()} };
			case EConst(c):
				switch (c) {
					case CIdent(name):
						//Instance is implicitly "this" or "ClassName" depending on static reference or not
						var cls = Context.getLocalClass().get();
						
						//Check class methods first
						if (hasMethod(cls, name)) {
							split = { inst: macro this, func:{expr:EConst(CString(name)), pos:Context.currentPos()} };
						}
						
						//Check class statics
						if (hasStaticFunction(cls, name)) {
							split = { inst:getFullClassName(cls), func:{expr:EConst(CString(name)), pos:Context.currentPos()} };
						}
					default:
						throw "Unsupported function reference.";
				}
			case EFunction(_, _):
				throw "Anonymous functions are not supported.";
			default:
				throw "Unsupported event handler.";
		}
		return macro { inst:${split.inst}, func:${split.func} };
	}
	
	macro static function store ():Array<Field> {
		var fields = Context.getBuildFields();
		var _fields = new Array<Field>();
		
		for (i in fields) {
			//Remove __listeners, public keyword and body content
			switch (i.kind) {
				case FFun(f):
					_fields.push( {
						pos:i.pos,
						name:i.name,
						meta:i.meta,
						kind:FFun( {
								ret:f.ret,
								params:f.params,
								expr:null,
								args:f.args
							}),
						doc:i.doc,
						access:[]
					});
				default:
			}
			
			edFields.push(i);
		}
		
		return _fields;
	}
	
	macro static function build ():Array<Field> {
		var fields = Context.getBuildFields();
		
		if (!hasMethod(Context.getLocalClass().get(), edFields[0].name)) {
			for (i in edFields) {
				fields.push(i);
			}
		}
		
		return fields;
	}
	#end
	
}