/**
 * Copyright 2010 Bernard Helyer.
 * Copyright 2010 Jakob Ovrum.
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 *
 * Jakob Sez: "best module, A++ would edit again :V"
 * Bernard Sez: "Hey! This is the _refactored_ version!"
 */
module sdc.parser.declaration;

import std.string;
import std.conv;
import std.exception;

import sdc.util;
import sdc.global;
import sdc.tokenstream;
import sdc.compilererror;
import sdc.ast.declaration;
import sdc.parser.base;
import sdc.parser.expression;
import sdc.parser.statement;
import sdc.parser.sdctemplate;
import sdc.extract.base;


Declaration parseDeclaration(TokenStream tstream)
{
    auto declaration = new Declaration();
    declaration.location = tstream.peek.location;
    
    if (tstream.peek.type == TokenType.Alias) {
        match(tstream, TokenType.Alias);
        if (tstream.peek.type == TokenType.Identifier && tstream.lookahead(1).type == TokenType.This) {
        	// alias foo this;
        	declaration.type = DeclarationType.AliasThis;
        	declaration.node = parseIdentifier(tstream);
        	match(tstream, TokenType.This);
        	match(tstream, TokenType.Semicolon);
        } else {
        	// Normal alias declaration.
		    if (tstream.peek.type == TokenType.Alias) {
		        throw new CompilerError(tstream.peek.location, "alias declarations cannot be the subject of an alias declaration.");
		    }
		    declaration.type = DeclarationType.Alias;
		    declaration.node = parseDeclaration(tstream);
        }
    } else if (tstream.peek.type == TokenType.Mixin) {
        declaration.type = DeclarationType.Mixin;
        declaration.node = parseMixinDeclaration(tstream);
    } else if (isVariableDeclaration(tstream)) {
        declaration.type = DeclarationType.Variable;
        declaration.node = parseVariableDeclaration(tstream);
    } else {
        declaration.type = DeclarationType.Function;
        declaration.node = parseFunctionDeclaration(tstream);
    }
    
    return declaration;
}

MixinDeclaration parseMixinDeclaration(TokenStream tstream)
{
    auto decl = new MixinDeclaration();
    decl.location = tstream.peek.location;
    match(tstream, TokenType.Mixin);
    match(tstream, TokenType.OpenParen);   
    decl.expression = parseAssignExpression(tstream);
    match(tstream, TokenType.CloseParen);
    match(tstream, TokenType.Semicolon); 
    return decl;
}

/**
 * Non destructively determines if the next declaration
 * is a variable, and summon an Elder God. 
 */
bool isVariableDeclaration(TokenStream tstream)
{
    if (tstream.peek.type == TokenType.Alias) {
        return true;
    }
    size_t lookahead = 0;
    Token token;
    while (true) {
        token = tstream.lookahead(lookahead);
        if ((contains(PAREN_TYPES, token.type) && tstream.lookahead(lookahead + 1).type == TokenType.OpenParen) ||
            token.type == TokenType.Typeof) {
            lookahead += 2;  // <paren type> <open paren>
            int parenCount = 1;
            do {
                token = tstream.lookahead(lookahead);
                if (token.type == TokenType.OpenParen) {
                    parenCount++;
                } else if (token.type == TokenType.CloseParen) {
                    parenCount--;
                } else if (token.type == TokenType.End) {
                    throw new CompilerError(token.location, "Unexpected EOF when parsing type.");
                }
                lookahead++;
            } while (parenCount > 0);
        }
        if (token.type == TokenType.End || token.type == TokenType.OpenBrace ||
            token.type == TokenType.OpenParen) {
            return false;
        } else if (token.type == TokenType.Semicolon || token.type == TokenType.Assign) {
            return true;
        }
        lookahead++;
    }
    assert(false);
}


VariableDeclaration parseVariableDeclaration(TokenStream tstream, bool noSemicolon = false)
{
    auto declaration = new VariableDeclaration();
    declaration.location = tstream.peek.location;
        
    declaration.type = parseType(tstream);
    
    auto declarator = new Declarator();
    declarator.location = tstream.peek.location;
    declarator.name = parseIdentifier(tstream);
    
    auto suffixes = parseTypeSuffixes(tstream, Placed.Insanely);
    if (tstream.peek.type == TokenType.Assign) {
        declarator.initialiser = parseInitialiser(tstream);
        declarator.location = declarator.initialiser.location - declarator.location;
    }
    declaration.declarators ~= declarator;
    if (suffixes.length > 0 && tstream.peek.type != TokenType.Semicolon) {
        throw new CompilerError(tstream.peek.location, "with multiple declarations, no declaration can use a c-style type suffix.");
    }
    declaration.type.suffixes ~= suffixes;
    if (!noSemicolon) {
        while (tstream.peek.type != TokenType.Semicolon) {
            // If there is no comma here, assume the user is missing a semicolon
            if(tstream.peek.type != TokenType.Comma) {
                if(declarator.initialiser is null) {
                    throw new MissingSemicolonError(declarator.name.location, "declaration");
                } else {
                    throw new MissingSemicolonError(declarator.initialiser.node.location, "initialisation");
                }
            }
            tstream.getToken();
            
            declarator = new Declarator();
            declarator.location = tstream.peek.location;
            declarator.name = parseIdentifier(tstream);
            if (tstream.peek.type == TokenType.Assign) {
                declarator.initialiser = parseInitialiser(tstream);
                declarator.location = declarator.initialiser.location - declarator.location;
            }
            declaration.declarators ~= declarator;
        }
        match(tstream, TokenType.Semicolon);
    }
    
    return declaration;
}

FunctionDeclaration parseFunctionDeclaration(TokenStream tstream)
{
    auto declaration = new FunctionDeclaration();
    declaration.location = tstream.peek.location;
    
    if (tstream.peek.type == TokenType.Auto && tstream.lookahead(1).type == TokenType.Identifier) {
        // TODO: look for function attributes here, as well. Once we have function attributes, of course. :P
        declaration.retval = parseInferredType(tstream);
    } else {
        declaration.retval = parseType(tstream);
    }
    declaration.name = parseIdentifier(tstream);
    verbosePrint("Parsing function '" ~ extractIdentifier(declaration.name) ~ "'.", VerbosePrintColour.Green);
    
    // If the next token isn't '(', assume the user missed a ';' off a variable declaration
    if(tstream.peek.type != TokenType.OpenParen) {
        throw new MissingSemicolonError(declaration.name.location, "declaration");
    }
    
    declaration.parameterList = parseParameters(tstream);
    if (tstream.peek.type == TokenType.OpenBrace) {
        declaration.functionBody = parseFunctionBody(tstream);
    } else {
        if(tstream.peek.type != TokenType.Semicolon) {
            throw new MissingSemicolonError(tstream.lookbehind(1).location, "function declaration");
        }
        tstream.getToken();
    }
    
    return declaration;
}

FunctionBody parseFunctionBody(TokenStream tstream)
{
    auto functionBody = new FunctionBody();
    functionBody.location = tstream.peek.location;
    functionBody.statement = parseBlockStatement(tstream);
    return functionBody;
}

immutable TokenType[] PRIMITIVE_TYPES = [
TokenType.Bool, TokenType.Byte, TokenType.Ubyte,
TokenType.Short, TokenType.Ushort, TokenType.Int,
TokenType.Uint, TokenType.Long, TokenType.Ulong,
TokenType.Cent, TokenType.Ucent,
TokenType.Char, TokenType.Wchar, TokenType.Dchar,
TokenType.Float, TokenType.Double, TokenType.Real,
TokenType.Ifloat, TokenType.Idouble, TokenType.Ireal,
TokenType.Cfloat, TokenType.Cdouble, TokenType.Creal,
TokenType.Void ];

immutable TokenType[] STORAGE_CLASSES = [
TokenType.Abstract, TokenType.Auto, TokenType.Const,
TokenType.Deprecated, TokenType.Extern, TokenType.Final,
TokenType.Immutable, TokenType.Inout, TokenType.Shared,
TokenType.Nothrow, TokenType.Override, TokenType.Pure,
TokenType.Scope, TokenType.Static, TokenType.Synchronized
];


Type parseType(TokenStream tstream)
{
    auto type = new Type();
    type.location = tstream.peek.location;
    
    while (contains(STORAGE_TYPES, tstream.peek.type)) {
        if (contains(PAREN_TYPES, tstream.peek.type)) {
            if (tstream.lookahead(1).type == TokenType.OpenParen) {
                switch (tstream.peek.type) {
                case TokenType.Const:
                    type.type = TypeType.ConstType;
                    break;
                case TokenType.Immutable:
                    type.type = TypeType.ImmutableType;
                    break;
                case TokenType.Inout:
                    type.type = TypeType.InoutType;
                    break;
                case TokenType.Shared:
                    type.type = TypeType.SharedType;
                    break;
                default:
                    throw new CompilerPanic(tstream.peek.location, "unexpected storage type token preceding open paren.");
                }
                tstream.getToken();
                match(tstream, TokenType.OpenParen);
                type.node = parseType(tstream);
                match(tstream, TokenType.CloseParen);
                goto PARSE_SUFFIXES;
            }
        }
        type.storageTypes ~= cast(StorageType) tstream.peek.type;
        tstream.getToken();
    }
    
    if (type.storageTypes.length > 0 &&
        tstream.peek.type == TokenType.Identifier &&
        tstream.lookahead(1).type == TokenType.Assign) {
        //
        type.type = TypeType.Inferred;
        return type;
    }
    
    if (contains(PRIMITIVE_TYPES, tstream.peek.type)) {
        type.type = TypeType.Primitive;
        type.node = parsePrimitiveType(tstream);
    } else if (tstream.peek.type == TokenType.Dot ||
               tstream.peek.type == TokenType.Identifier) {
        type.type = TypeType.UserDefined;
        type.node = parseUserDefinedType(tstream);
    } else if (tstream.peek.type == TokenType.Typeof) {
        type.type = TypeType.Typeof;
        type.node = parseTypeofType(tstream);
    } else if (tstream.peek.type == TokenType.Const) {
        type.type = TypeType.ConstType;
        match(tstream, TokenType.Const);
        match(tstream, TokenType.OpenParen);
        type.node = parseType(tstream);
        match(tstream, TokenType.CloseParen);
    } else if (tstream.peek.type == TokenType.Immutable) {
        type.type = TypeType.ImmutableType;
        match(tstream, TokenType.Immutable);
        match(tstream, TokenType.OpenParen);
        type.node = parseType(tstream);
        match(tstream, TokenType.CloseParen);
    } else if (tstream.peek.type == TokenType.Shared) {
        type.type = TypeType.SharedType;
        match(tstream, TokenType.Shared);
        match(tstream, TokenType.OpenParen);
        type.node = parseType(tstream);
        match(tstream, TokenType.CloseParen);
    } else if (tstream.peek.type == TokenType.Inout) {
        type.type = TypeType.InoutType;
        match(tstream, TokenType.Inout);
        match(tstream, TokenType.OpenParen);
        type.node = parseType(tstream);
        match(tstream, TokenType.CloseParen);
    }
    
    if (tstream.peek.type == TokenType.Function) {
        auto initialType = type;
        type = new Type();
        type.type = TypeType.FunctionPointer;
        type.node = parseFunctionPointerType(tstream, initialType);
    } else if (tstream.peek.type == TokenType.Delegate) {
        auto initialType = type;
        type = new Type();
        type.type = TypeType.Delegate;
        type.node = parseDelegateType(tstream, type);
    } else if (tstream.peek.type == TokenType.OpenParen &&
               tstream.lookahead(1).type == TokenType.Asterix) {
        throw new CompilerError(tstream.peek.location, "C style pointer/array declaration syntax is unsupported.");
    }
    
PARSE_SUFFIXES:
    type.suffixes = parseTypeSuffixes(tstream, Placed.Sanely);
    return type;
}

Type parseInferredType(TokenStream tstream)
{
    auto type = new Type();
    type.location = tstream.peek.location;
    match(tstream, TokenType.Auto);
    type.type = TypeType.Inferred;
    return type;
}

enum Placed { Sanely, Insanely }
TypeSuffix[] parseTypeSuffixes(TokenStream tstream, Placed placed)
{
    auto SUFFIX_STARTS = placed == Placed.Sanely ?
                         [TokenType.Asterix, TokenType.OpenBracket] :
                         [TokenType.OpenBracket];
        
    TypeSuffix[] suffixes;
    while (contains(SUFFIX_STARTS, tstream.peek.type)) {
        auto suffix = new TypeSuffix();
        if (placed == Placed.Sanely && tstream.peek.type == TokenType.Asterix) {
            match(tstream, TokenType.Asterix);
            suffix.type = TypeSuffixType.Pointer;
        } else if (tstream.peek.type == TokenType.OpenBracket) {
            match(tstream, TokenType.OpenBracket);
            if (tstream.peek.type == TokenType.CloseBracket) {
                suffix.type = TypeSuffixType.DynamicArray;
            } else if (contains(PRIMITIVE_TYPES, tstream.peek.type) ||
                       tstream.peek.type == TokenType.Identifier ||
                       (tstream.peek.type == TokenType.Dot &&
                        tstream.lookahead(1).type == TokenType.Identifier)) {
                suffix.node = parseType(tstream);
                suffix.type = TypeSuffixType.AssociativeArray;
            } else {
                suffix.node = parseExpression(tstream);
                suffix.type = TypeSuffixType.StaticArray;
            }
            match(tstream, TokenType.CloseBracket);
        } else {
            assert(false);
        }
        suffixes ~= suffix;
    }
    return suffixes;
}

/**
 * Non-destructively determine, if the stream is on a primitive type,
 * what kind of declaration follows; a simple primitive variable,
 * a function pointer, or a delegate.
 */
TypeType typeFromPrimitive(TokenStream tstream)
in
{
    assert(contains(PRIMITIVE_TYPES, tstream.peek.type));
}
out(result)
{
    assert(result == TypeType.Primitive ||
           result == TypeType.FunctionPointer ||
           result == TypeType.Delegate);
}
body
{
    auto result = TypeType.Primitive;
    size_t lookahead = 1;
    while (true) {
        auto token = tstream.lookahead(lookahead);
        if (token.type == TokenType.OpenParen) {
            int nesting = 1;
            while (nesting > 0) {
                lookahead++;
                token = tstream.lookahead(lookahead);
                switch (token.type) {
                case TokenType.End:
                    throw new CompilerError(tstream.peek.location, "expected declaration, got EOF.");
                case TokenType.OpenParen:
                    nesting++;
                    break;
                case TokenType.CloseParen:
                    nesting--;
                    break;
                default:
                    break;
                }
            }
            lookahead++;
        }
        if (token.type == TokenType.End) {
            throw new CompilerError(tstream.peek.location, "expected declaration, got EOF.");
        } else if (token.type == TokenType.Identifier) {
            break;
        } else if (token.type == TokenType.Delegate) {
            return TypeType.Delegate;
        } else if (token.type == TokenType.Function) {
            return TypeType.FunctionPointer;
        }
        lookahead++;
    }
    return result;
}


PrimitiveType parsePrimitiveType(TokenStream tstream)
{
    auto primitive = new PrimitiveType();
    primitive.location = tstream.peek.location;
    enforce(contains(PRIMITIVE_TYPES, tstream.peek.type));
    primitive.type = cast(PrimitiveTypeType) tstream.peek.type;
    tstream.getToken();
    return primitive;
}

UserDefinedType parseUserDefinedType(TokenStream tstream)
{
    auto type = new UserDefinedType();
    type.location = tstream.peek.location;
    
    type.segments ~= parseIdentifierOrTemplateInstance(tstream);
    while (tstream.peek.type == TokenType.Dot) {
        match(tstream, TokenType.Dot);
        type.segments ~= parseIdentifierOrTemplateInstance(tstream);        
    }
    return type;
}

IdentifierOrTemplateInstance parseIdentifierOrTemplateInstance(TokenStream tstream)
{
    auto node = new IdentifierOrTemplateInstance();
    node.location = tstream.peek.location;
    if (tstream.lookahead(1).type == TokenType.Bang) {
        node.isIdentifier = false;
        node.node = parseTemplateInstance(tstream);
    } else {
        node.isIdentifier = true;
        node.node = parseIdentifier(tstream);
    }
    return node;
}

TypeofType parseTypeofType(TokenStream tstream)
{
    auto type = new TypeofType();
    type.location = tstream.peek.location;
    
    match(tstream, TokenType.Typeof);
    match(tstream, TokenType.OpenParen);
    if (tstream.peek.type == TokenType.This) {
        type.type = TypeofTypeType.This;
    } else if (tstream.peek.type == TokenType.Super) {
        type.type = TypeofTypeType.Super;
    } else if (tstream.peek.type == TokenType.Return) {
        type.type = TypeofTypeType.Return;
    } else {
        type.type = TypeofTypeType.Expression;
        type.expression = parseExpression(tstream);
    }
    match(tstream, TokenType.CloseParen);
    
    if (tstream.peek.type == TokenType.Dot) {
        match(tstream, TokenType.Dot);
        type.qualifiedName = parseQualifiedName(tstream);
    }
    
    return type;
}

FunctionPointerType parseFunctionPointerType(TokenStream tstream, Type retval)
{
    auto type = new FunctionPointerType();
    type.location = tstream.peek.location;
    
    type.retval = retval;
    match(tstream, TokenType.Function);
    type.parameters = parseParameters(tstream);
    
    return type;
}

DelegateType parseDelegateType(TokenStream tstream, Type retval)
{
    auto type = new DelegateType();
    type.location = tstream.peek.location;
    
    type.retval = retval;
    match(tstream, TokenType.Delegate);
    type.parameters = parseParameters(tstream);
    
    return type;
}

ParameterList parseParameters(TokenStream tstream)
{
    auto list = new ParameterList();
    auto openParen = match(tstream, TokenType.OpenParen);
    
    while(tstream.peek.type != TokenType.CloseParen) {
        auto parameter = new Parameter();
        parameter.location = tstream.peek.location;
        
        if (tstream.peek.type == TokenType.TripleDot) {
            list.varargs = true;
            tstream.getToken();
            if (tstream.peek.type != TokenType.CloseParen) {
                throw new CompilerError(tstream.peek.location, "varargs must appear last in the parameter list.");
            }
            break;
        }
        
        switch (tstream.peek.type) with (TokenType) {
        case In:
            parameter.attribute = ParameterAttribute.In;
            break;
        case Out:
            parameter.attribute = ParameterAttribute.Out;
            break;
        case Lazy:
            parameter.attribute = ParameterAttribute.Lazy;
            break;
        case Ref:
            parameter.attribute = ParameterAttribute.Ref;
            break;
        default:
            parameter.attribute = ParameterAttribute.None;
            break;
        }
        if (parameter.attribute != ParameterAttribute.None) {
            tstream.getToken();
        }
               
        parameter.type = parseType(tstream);
        if (tstream.peek.type == TokenType.Identifier) {
            parameter.identifier = parseIdentifier(tstream);
            parameter.location = parameter.identifier.location - parameter.location;
            // Parse default argument (if any).
            if (tstream.peek.type == TokenType.Assign) {
                match(tstream, TokenType.Assign);
                if (tstream.peek.type == TokenType.__File__) {
                    match(tstream, TokenType.__File__);
                    parameter.defaultArgumentFile = true;
                } else if (tstream.peek.type == TokenType.__Line__) {
                    match(tstream, TokenType.__Line__);
                    parameter.defaultArgumentLine = true;
                } else {
                    parameter.defaultArgument = parseAssignExpression(tstream);
                }
            }
        }
        list.parameters ~= parameter;
        if (tstream.peek.type == TokenType.CloseParen) {
            break;
        }
        match(tstream, TokenType.Comma);
    }
    auto closeParen = match(tstream, TokenType.CloseParen);
    
    list.location = closeParen.location - openParen.location;
    return list;
}

Initialiser parseInitialiser(TokenStream tstream)
{
    auto initialiser = new Initialiser();
    initialiser.location = tstream.peek.location;
    match(tstream, TokenType.Assign);
    
    switch (tstream.peek.type) {
    case TokenType.Void:
        match(tstream, TokenType.Void);
        initialiser.type = InitialiserType.Void;
        break;
    default:
        initialiser.type = InitialiserType.AssignExpression;
        initialiser.node = parseAssignExpression(tstream);
        break;
    }
    
    // Hey! If you see this quick fix, feel free to spend some time
    // thinking whether it's a sufficiently good one or not :)
    initialiser.location = tstream.lookbehind(1).location - initialiser.location;
    return initialiser;
}


bool startsLikeDeclaration(TokenStream tstream)
{
    /* TODO: this is horribly incomplete. The TokenStream should be 
     * thoroughly (but non-destructively) examined, not the simple
     * 'search through keywords' function that is here now.
     */
    auto t = tstream.peek.type;
    
    if (t == TokenType.Identifier) {
        size_t l = 1;
        while (tstream.lookahead(l).type == TokenType.Dot) {
            l++;
            if (tstream.lookahead(l).type == TokenType.Identifier) {
                l++;
                continue;
            }
            return false;
        }
        if (tstream.lookahead(l).type == TokenType.Identifier) {
            return true;
        }
    }
    
    return t == TokenType.Alias || t == TokenType.Typeof || contains(PRIMITIVE_TYPES, t) || contains(STORAGE_CLASSES, t);
}

