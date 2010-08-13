/**
 * Copyright 2010 Bernard Helyer
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.value;

import std.string;

import llvm.c.Core;
import llvm.Ext;

import sdc.compilererror;
import sdc.location;
import sdc.extract.base;
import sdc.gen.sdcmodule;
import sdc.gen.type;


abstract class Value
{
    /// The location that this Value was created at.
    Location location;
    
    this(Module mod, Location loc)
    {
        mModule = mod;
        location = loc;
    }
    
    /*
     * This is not related to the attributes 'const' or 'immutable'.
     * This boolean and the following union are all in aid of constant
     * folding. If constant is true, then this Value has been constructed
     * out of all compile time known values, thus this value is known at 
     * compile time. This will be used in places like assert, static 
     * arrays, bounds checked type conversions -- places in the D spec 
     * where constant folding is required.
     */
    bool constant;
    union
    {
        bool constBool;
        int constInt;
    }
    
    Type type() @property
    {
        return mType;
    }
    
    void type(Type t) @property
    {
        mType = t;
    }
    
    void castTo(Type t)
    {
        panic(location, "invalid cast");
    }
    
    LLVMValueRef get();
    void set(Value val);
    void set(LLVMValueRef val);
    void add(Value val);
    void sub(Value val);
    Value call(Value[] args);
    Value init(Location location);
    
    protected Module mModule;
    protected Type mType;
    protected LLVMValueRef mValue;
}

mixin template InvalidOperation(alias FunctionSignature)
{
    mixin("override " ~ FunctionSignature ~ " {"
          `    panic(location, "invalid operation used."); assert(false); }`);
}

    
class PrimitiveIntegerValue(T, B, alias C) : Value
{
    this(Module mod, Location loc)
    { 
        super(mod, loc);
        mType = new B(mod);
        mValue = LLVMBuildAlloca(mod.builder, mType.llvmType, "int");
    }
    
    this(Module mod, Location loc, T n)
    {
        this(mod, loc);
        constInit(n);
    }
    
    this(Module mod, Value val)
    {
        this(mod, val.location);
        set(val);
    }
    
    override void castTo(Type t)
    {
        auto v = LLVMBuildIntCast(mModule.builder, get(), t.llvmType, "cast");
        mValue = LLVMBuildAlloca(mModule.builder, LLVMTypeOf(v), "castalloca");
        LLVMBuildStore(mModule.builder, v, mValue);
        mType = t;
    }
    
    override LLVMValueRef get()
    {
        return LLVMBuildLoad(mModule.builder, mValue, "primitive");
    }
    
    override void set(Value val)
    {
        this.constant = this.constant && val.constant;
        if (this.constant) {
            mixin(C ~ " = val." ~ C ~ ";");
        }
        LLVMBuildStore(mModule.builder, val.get(), mValue);
    }
    
    override void set(LLVMValueRef val)
    {
        constant = false;
        LLVMBuildStore(mModule.builder, val, mValue);
    }
    
    override void add(Value val)
    {
        this.constant = this.constant && val.constant;
        if (this.constant) {
            mixin(C ~ " = cast(" ~ T.stringof ~ ")(" ~ C ~ " + val." ~ C ~ ");");
        }
        auto result = LLVMBuildAdd(mModule.builder, this.get(), val.get(), "add");
        LLVMBuildStore(mModule.builder, result, mValue);
    }
    
    override void sub(Value val)
    {
        this.constant = this.constant && val.constant;
        if (this.constant) {
            mixin(C ~ " = cast(" ~ T.stringof ~ ")(" ~ C ~ " - val." ~ C ~ ");");
        }
        auto result = LLVMBuildSub(mModule.builder, this.get(), val.get(), "add");
        LLVMBuildStore(mModule.builder, result, mValue);
    }
    
    mixin InvalidOperation!"Value call(Value[])";
    
    override Value init(Location location)
    {
        return new typeof(this)(mModule, location, 0);
    }
    
    protected void constInit(T n)
    {
        auto val = LLVMConstInt(mType.llvmType(), n, false);
        LLVMBuildStore(mModule.builder, val, mValue);
        constant = true;
        mixin(C ~ " = n;");
    }
}

alias PrimitiveIntegerValue!(bool, BoolType, "constBool") BoolValue;
alias PrimitiveIntegerValue!(int, IntType, "constInt") IntValue;



class FunctionValue : Value
{
    this(Module mod, Location location, FunctionType func, string name)
    {
        super(mod, location);
        mType = func;
        mValue = LLVMAddFunction(mod.mod, toStringz(name), func.llvmType);
    }
    
    override LLVMValueRef get()
    {
        return mValue;
    }
    
    override Value call(Value[] args)
    {
        // Check call with function signature.
        auto functionType = cast(FunctionType) mType;
        assert(functionType);
        if (functionType.argumentTypes.length != args.length) {
            goto err;
        }
        foreach (i, arg; functionType.argumentTypes) {
            if (arg != args[i].type) {
                goto err;
            }
        }
        
        LLVMValueRef[] llvmArgs;
        foreach (arg; args) {
            llvmArgs ~= arg.get();
        }
        
        auto retval = LLVMBuildCall(mModule.builder, mValue, llvmArgs.ptr, llvmArgs.length, "call");
        auto val = functionType.returnType.getValue(location);
        val.set(retval);
        return val;
        
    err:
        error(location, "can't call function with given arguments.");
        assert(false);
    }
    
    mixin InvalidOperation!"void set(Value)";
    mixin InvalidOperation!"void set(LLVMValueRef)";
    mixin InvalidOperation!"void add(Value)";
    mixin InvalidOperation!"void sub(Value)";
    
    override Value init(Location location)
    {
        panic(location, "tried to get the init of a function value.");
        assert(false);
    }
}


// I hope it's obvious that the following are stub functions.

Value astTypeToBackendValue(ast.Type type, Module mod)
{
    switch (type.type) {
    case ast.TypeType.Primitive:
        return primitiveTypeToBackendValue(cast(ast.PrimitiveType) type.node, mod);
    default:
        panic(type.location, "unhandled type type.");
    }
    
    assert(false);
}

Value primitiveTypeToBackendValue(ast.PrimitiveType type, Module mod)
{
    switch (type.type) {
    case ast.PrimitiveTypeType.Bool:
        return new BoolValue(mod, type.location);
    case ast.PrimitiveTypeType.Int:
        return new IntValue(mod, type.location);
    default:
        panic(type.location, "unhandled primitive type type.");
    }
    
    assert(false);
}