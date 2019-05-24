#!/usr/bin/env rund
//!debug
//!debugSymbols

import core.stdc.stdlib : exit;

import std.exception, std.conv, std.array, std.string, std.algorithm;
import std.path, std.file, std.stdio, std.process;
alias write = std.stdio.write;

__gshared ShellObject[string] globalSysVars;

void usage()
{
    writeln("Usage: tbdscript <file> <args>...");
    writeln("       tbdscript -c \"<command>\"");
}
int main(string[] args)
{
    args = args[1 .. $];
    if (args.length == 0)
    {
        usage();
        return 1;
    }
    globalSysVars["echoCommands"] = ShellObject.makeString("0");
    globalSysVars["getuid"] = ShellObject.makeNoArgStringFunc("$sys.getuid", &getuidFunc);
    if (args[0] == "-c")
    {
        if (args.length > 2)
        {
            writeln("Error: the -c option only accepts one argument");
            return 1;
        }
        auto topLevelScript = Script("<from -c>");
        Script.current = &topLevelScript;
        executeCommand(args[1].asLimitArray.splitAndExpand);
    }
    else
    {
        auto topLevelScript = Script(args[0]);
        auto argsArray = new ShellObject[args.length];
        foreach (i, arg; args)
        {
            argsArray[i] = ShellObject.makeString(arg);
            topLevelScript.vars[i.to!string] = ShellObject.makeString(arg);
        }
        topLevelScript.sysVars["argv"] = ShellObject.makeArray(argsArray);
        topLevelScript.execute();
    }
    return 0;
}

enum ShellObjectType
{
    string_,
    array,
    obj,
    func,
    noArgStringFunc,
}
alias InternalFunc = int function(ShellObject[] args, Redirects* redirects);
alias NoArgStringFunc = string function();
struct ShellObject
{
    ShellObjectType type;
    union
    {
        struct
        {
            string str;
        }
        struct
        {
            ShellObject[] array;
        }
        struct
        {
            ShellObject[string] obj;
        }
        struct
        {
            string funcName;
            InternalFunc funcPtr;
        }
        struct
        {
            string noArgStringFuncName;
            NoArgStringFunc noArgStringFuncPtr;
        }
    }
    bool hasValue() const { return type != ubyte.max; }
    bool equalsString(string str) const
    {
        return (this.type == ShellObjectType.string_) && (this.str == str);
    }
    static ShellObject noValue()
    {
        ShellObject obj = void;
        obj.type = cast(ShellObjectType)ubyte.max;
        return obj;
    }
    static ShellObject makeString(string str)
    {
        ShellObject obj = void;
        obj.type = ShellObjectType.string_;
        obj.str = str;
        return obj;
    }
    static ShellObject makeArray(ShellObject[] array)
    {
        ShellObject obj = void;
        obj.type = ShellObjectType.array;
        obj.array = array;
        return obj;
    }
    static ShellObject makeObject(ShellObject[string] objDictionary)
    {
        ShellObject obj = void;
        obj.type = ShellObjectType.obj;
        obj.obj = objDictionary;
        return obj;
    }
    static ShellObject makeFunction(string name, InternalFunc func)
    {
        ShellObject obj = void;
        obj.type = ShellObjectType.func;
        obj.funcName = name;
        obj.funcPtr = func;
        return obj;
    }
    static ShellObject makeNoArgStringFunc(string name, NoArgStringFunc func)
    {
        ShellObject obj = void;
        obj.type = ShellObjectType.noArgStringFunc;
        obj.noArgStringFuncName = name;
        obj.noArgStringFuncPtr = func;
        return obj;
    }
}

auto limitArray(T)(T* ptr, T* limit)
in { assert(ptr <= limit); } do
{ return LimitArray!T(ptr, limit); }

LimitArray!T asLimitArray(T)(T[] array)
{
    return LimitArray!T(array.ptr, array.ptr + array.length);
}
struct LimitArray(T)
{
    T* ptr;
    T* limit;
    bool empty() const { return ptr == limit; }
    auto front() inout { return ptr[0]; }
    void popFront() { ptr++; }
    auto asArray() inout { return ptr[0 .. limit-ptr]; }
    static if (is(T == char))
    {
        char[] toString() { return ptr[0 .. limit-ptr]; }
    }
}
void skip(Range, U)(Range* range, U value)
{
    for (;!range.empty && range.front == value; range.popFront)
    { }
}
void until(Range, U)(Range* range, U value)
{
    for (;!range.empty && range.front != value; range.popFront)
    { }
}

struct LineBuilder(C)
{
    private Appender!(C[]) appender;
    private bool started; // need this because appender could be started AND empty
    void put(C[] part)
    {
        this.started = true;
        appender.put(part);
    }
    auto finish(C[] lastPart)
    {
        if (!started)
            return lastPart;
        appender.put(lastPart);
        return appender.data;
    }
}
struct LineContinuationRange(C)
{
    struct Result { C[] text; uint count; }

    private char* nextLineStart;
    Result result;
    this(C* ptr) { this.nextLineStart = ptr; popFront(); }
    bool empty() const { return result.text is null; }
    auto front() inout { return result; }
    void popFront()
    {
        LineBuilder!C lineBuilder;
        result.count = 0;
        for (;;)
        {
            if (nextLineStart[0] == '\0')
            {
                result.text = lineBuilder.finish(null);
                return;
            }
            auto saveStart = nextLineStart;
            auto next = nextLineStart;
            for (;;)
            {
                if (next[0] == '\n')
                {
                    nextLineStart = next + 1;
                    break;
                }
                next++;
                if (next[0] == '\0')
                {
                    nextLineStart = next;
                    break;
                }
            }

            result.count++;
            // Check for line continuation '\'
            if (next == saveStart || (next-1)[0] != '\\')
            {
                result.text = lineBuilder.finish(saveStart[0 .. next - saveStart]);
                return;
            }
            lineBuilder.put(saveStart[0 .. next - saveStart - 1]);
        }
    }
}
/+
auto stripComment(T)(LimitArray!T line)
{
    auto start = line.ptr;
    for (;!line.empty && line.front != '#';)
    {
        if (line.front == '"')
            line.ptr = scanQuotedString(line).end;
        else
            line.popFront;
    }
    return limitArray(start, line.ptr);
}

// Replace quote pairs ("") with one quote (")
char[] escapeString(T)(T[] str)
{
    auto newString = new char[str.length];
    size_t newIndex = 0;
    for (size_t oldIndex = 0; oldIndex < str.length; oldIndex++)
    {
        newString[newIndex++] = str[oldIndex];
        if (str[oldIndex] == '"')
            oldIndex++;
    }
    return newString[0 .. newIndex];
}

// Assumption: str points to the opening quote
auto scanQuotedString(T)(LimitArray!T str)
{
    //writefln("[DEBUG] scanQuotedString '%s'", str);
    static struct Result { T* end; bool hasEscapes; }
    bool hasEscapes = false;

    str.popFront;
    auto save = str.ptr;
    for (;;str.popFront)
    {
        if (str.empty)
        {
            errorf("unterminted quoted string");
            assert(0);
        }
        if (str.front == '"')
        {
             str.popFront;
             if (str.empty || str.front != '"')
                 return Result(str.ptr, hasEscapes);
             hasEscapes = true;
        }
    }
}
struct FixedAppender(T)
{
    private T[] array;
    private size_t length;
    auto data() inout { return array[0 .. length]; }
    void put(T e) { array[length++] = e; }
}
+/

struct Script
{
    static Script* current = null;

    string filename;
    string filenameAbsolute;
    string dirAbsolute;
    ShellObject[string] sysVars;
    ShellObject[string] vars;
    uint lineNumberMin;
    uint lineNumberMax;
    IfState[] ifStack;
    void execute()
    {
        sysVars["file"] = ShellObject.makeString(filename);
        filenameAbsolute = absolutePath(filename);
        sysVars["abs_file"] = ShellObject.makeString(filenameAbsolute);
        dirAbsolute = dirName(filenameAbsolute);
        sysVars["abs_dir"] = ShellObject.makeString(dirAbsolute);

        lineNumberMax = 0;
        auto parentScript = Script.current;
        Script.current = &this;
        scope (exit) Script.current = parentScript;

        const fileContent = FileContent(filename);
        foreach (line; FileContent(filename).byLine)
        {
            lineNumberMin = lineNumberMax + 1;
            lineNumberMax = lineNumberMin + line.count - 1;
            //writefln("line %s '%s'", lineNumber, line);

            auto lineText = line.text.strip().asLimitArray/*.stripComment()*/;

            // we have to handle conditionals before expansion becuase
            // we don't want to expand the condition if we aren't executing it
            if (handleConditionals(lineText))
                continue;
            if (isCurrentBlockDisabled)
                continue;

            executeCommand(lineText.splitAndExpand);
        }

        if (ifStack.length > 0)
            errorf("missing %s 'fi' terminator(s)", ifStack.length);
    }
}

struct FileContent
{
    string filename;
    char[] text;
    this(string filename)
    {
        this.filename = filename;
        auto file = File(filename, "rb");
        const fileSize = file.size;
        if (fileSize + 1 > size_t.max)
            errorf("file '%s' is too large: %s", filename, fileSize);
        auto buffer = new char[cast(size_t)(fileSize + 1)];
        this.text = buffer[0 .. $-1];
        const length = file.rawRead(this.text).length;
        if (length != this.text.length)
            errorf("rawRead of '%s' with length %s returned %s", filename, this.text.length, length);
        buffer[$-1] = '\0';
    }
    auto byLine()
    {
        return LineContinuationRange!char(text.ptr);
    }
}

string errorf(T...)(T args)
{
    pragma(inline, true);
    errorfTo(std.stdio.stdout, args);
    assert(0);
}
string errorfTo(T...)(File file, T args)
{
    if (Script.current)
    {
        if (Script.current.lineNumberMin == Script.current.lineNumberMax)
            file.writef("%s(line %s) ", Script.current.filename, Script.current.lineNumberMin);
        else
            file.writef("%s(lines %s-%s) ", Script.current.filename, Script.current.lineNumberMin, Script.current.lineNumberMax);
    }
    file.writefln(args);
    exit(1);
    assert(0);
}

ShellObject[] splitAndExpand(T)(LimitArray!T s)
{
    Appender!(ShellObject[]) objs;
    splitAndExpandInto(s, &objs);
    return objs.data;
}
void splitAndExpandInto(T)(LimitArray!T s, Appender!(ShellObject[])* objs)
{
    auto rest = s;
  OuterLoop:
    for (;;)
    {
        skip(&rest, ' ');
        if (rest.empty)
            break;

        if (rest.front == '#')
            break;

        bool insideQuote = false;
        Appender!(T[]) argBuilder;
        if (rest.front == '$')
        {
            Appender!(T[]) argStringBuilder;
            auto obj = ShellObject.noValue;
            rest.ptr = expand(rest, &obj, &argStringBuilder);
            if (rest.empty || rest.front == ' ')
            {
                if (obj.hasValue)
                {
                    assert(argStringBuilder.data.length == 0);
                    objs.put(obj);
                }
                else
                {
                    objs.put(ShellObject.makeString(argStringBuilder.data.assumeUnique));
                }
                continue;
            }
            if (obj.hasValue)
            {
                if (obj.type != ShellObjectType.string_)
                    assert(0, errorf("non-string '$' must appear on their own"));
                argBuilder.put(obj.str);
            }
        }
        else if (rest.front == '"')
        {
            insideQuote = true;
            rest.popFront;
        }

        for (;;)
        {
            if (rest.front == '#')
            {
                if (!insideQuote)
                {
                    errorf("found '#' inside a token, should this be a comment, just a character, or an error?");
                    assert(0);
                }
                argBuilder.put('#');
                rest.popFront;
            }
            else if (rest.front == '"')
            {
                if (!insideQuote)
                {
                    errorf(`found a '"' inside a token, I think this should be an error but not sure`);
                    assert(0);
                }
                rest.popFront;
                if (rest.empty || rest.front != '"')
                    break;
                argBuilder.put('"');
                rest.popFront;
            }
            else if (rest.front == '$')
            {
                auto obj = ShellObject.noValue;
                rest.ptr = expand(rest, &obj, &argBuilder);
                if (obj.hasValue)
                {
                    if (obj.type != ShellObjectType.string_)
                        assert(0, errorf("non-string '$' must appear on their own"));
                    argBuilder.put(obj.str);
                }
            }
            else if (!insideQuote && rest.front == ' ')
                break;
            else
            {
                argBuilder.put(rest.front);
                rest.popFront;
            }
            if (rest.empty)
                break;
        }
        objs.put(ShellObject.makeString(argBuilder.data.assumeUnique));
    }
}

// s points to the '$' character
T* expand(T)(LimitArray!T s, ShellObject* result, Appender!(T[])* argBuilder)
{
    //writefln("[DEBUG] s = '%s'", s);
    auto next = s;
    next.popFront;
    if (next.empty)
        assert(0, errorf("empty '$' expression"));

    if (next.front == '{')
    {
        // TODO: support balanced parens? recursive expansion?
        next.popFront;
        auto start = next.ptr;
        for (;; next.popFront)
        {
            if (next.empty)
                errorf("unterminated '${...' expression");
            if (next.front == '}')
                break;
        }
        //argBuilder.put(resolveToString(start[0 .. next.ptr - start]));
        *result = resolve(start[0 .. next.ptr - start]);
        next.popFront;
        return next.ptr;
    }

    if (next.front == '(')
    {
        assert(0, errorf("$(...) not implemented"));
    }

    else if (next.front == '$')
    {
        argBuilder.put("$");
        next.popFront;
        return next.ptr;
    }

    auto start = next.ptr;
    for (; validVarChar(next.front);)
    {
        next.popFront;
        if (next.empty)
            break;
    }
    if (start == next.ptr)
        errorf("empty '$' expression");

    //argBuilder.put(resolveToString(start[0 .. next.ptr - start]));
    *result = resolve(start[0 .. next.ptr - start]);
    return next.ptr;
}

auto sliceTo(T)(T* start, T* limit)
in { assert(limit >= start); } do
{
    return start[0 .. limit - start];
}

// [a-zA-Z0-9_]
bool validVarChar(const char c)
{
    if (c < 'A')
        return (c >= '0' && c <= '9') || c == '.';
    if (c <= 'Z')
        return true;
    if (c == '_')
        return true;
    return (c >= 'a' && c <= 'z');
}

auto resolveToString(const(char)[] varname)
{
    auto obj = resolve(varname);
    if (obj.type == ShellObjectType.string_)
        return obj.str;
    errorf("object '%s' is not a string, it's type is %s", varname, obj.type);
    assert(0);
}
ShellObject resolve(const(char)[] varname)
{
    auto result = resolveImpl(varname);
    if (result.type == ShellObjectType.noArgStringFunc)
        return ShellObject.makeString(result.noArgStringFuncPtr());
    return result;
}
ShellObject resolveImpl(const(char)[] varname)
{
    const dotIndex = varname.indexOf('.');
    if (dotIndex == -1)
    {
        const result = tryResolveUnqualified(varname);
        if (result.hasValue)
            return result;
    }
    else
    {
        const obj = varname[0 .. dotIndex];
        const field = varname[dotIndex + 1 .. $];
        if (obj == "opt")
        {
            const result = tryResolveUnqualified(field);
            return result.hasValue ? result : ShellObject.makeString("");
        }

        if (obj == "sys")
        {
            {
                auto result = Script.current.sysVars.get(cast(string)field, ShellObject.noValue);
                if (result.hasValue)
                    return result;
            }
            {
                auto result = globalSysVars.get(cast(string)field, ShellObject.noValue);
                if (result.hasValue)
                    return result;
            }
        }
        else
        {
            errorf("unknown object '%s' in variable '%s'", obj, varname);
            assert(0);
        }
    }
    errorf("unknown variable '%s'", varname);
    assert(0);
}
ShellObject tryResolveUnqualified(const(char)[] basename)
{
    {
        auto result = Script.current.vars.get(cast(string)basename, ShellObject.noValue);
        if (result.hasValue)
            return result;
    }
    {
        auto result = environment.get(basename, null);
        if (result)
            return ShellObject.makeString(result);
    }
    return ShellObject.noValue;
}

void setvar(string varname, string value)
{
    const dotIndex = varname.indexOf('.');
    if (dotIndex == -1)
    {
        Script.current.vars[varname] = ShellObject.makeString(value);
    }
    else
    {
        const obj = varname[0 .. dotIndex];
        const field = varname[dotIndex + 1 .. $];
        if (obj == "sys")
        {
            // TODO: global or local?
            // Script.current.sysVars?
            // globalSysVars?
            globalSysVars[field] = ShellObject.makeString(value);
        }
        else
        {
            errorf("unknown object '%s' in variable '%s'", obj, varname);
            assert(0);
        }
    }
}

auto executeForExpand(T)(T[] cmd)
{
    errorf("$(...) not implemented");
    //writefln("WARNING: TODO: executeForExpand $(", cmd, ")");
    return "?????";
}


struct Redirects
{
    File out_;
    File err;
    string errorf(T...)(T args)
    {
        pragma(inline, true);
        errorfTo(err, args);
        assert(0);
    }
}


/*
auto parseRedirect(scope const(char[])[] args, Redirects* redirects)
{
    if (args.length >= 2)
    {
        if (args[$-2] == ">")
            redirects.out_ = File(args[$-1], "wb");
        else if (args[$-2] == "2>")
            redirects.err = File(args[$-1], "wb");
        else if (args[$-2] == "&>")
        {
            redirects.out_ = File(args[$-1], "wb");
            redirects.err = redirects.out_;
        }
        else if (args[$-2] == ">>")
            redirects.out_ = File(args[$-1], "ab");
        else if (args[$-2] == "2>>")
            redirects.err = File(args[$-1], "ab");
        else if (args[$-2] == "&>>")
        {
            redirects.out_ = File(args[$-1], "ab");
            redirects.err = redirects.out_;
        }
        else
            return args;

        return args[0 .. $-2];
    }
    return args;
}
*/
auto parseRedirect(ShellObject[] args, Redirects* redirects)
{
    if (args.length >= 2)
    {
        // require last arg to be string for now
        if (args[$-1].type != ShellObjectType.string_)
            return args;

        if (args[$-2].equalsString(">"))
            redirects.out_ = File(args[$-1].str, "wb");
        else if (args[$-2].equalsString("2>"))
            redirects.err = File(args[$-1].str, "wb");
        else if (args[$-2].equalsString("&>"))
        {
            redirects.out_ = File(args[$-1].str, "wb");
            redirects.err = redirects.out_;
        }
        else if (args[$-2].equalsString(">>"))
            redirects.out_ = File(args[$-1].str, "ab");
        else if (args[$-2].equalsString("2>>"))
            redirects.err = File(args[$-1].str, "ab");
        else if (args[$-2].equalsString("&>>"))
        {
            redirects.out_ = File(args[$-1].str, "ab");
            redirects.err = redirects.out_;
        }
        else
            return args;

        return args[0 .. $-2];
    }
    return args;
}

void writeCommand(ShellObject[] objs)
{
    foreach (obj; objs)
    {
        final switch(obj.type)
        {
        case ShellObjectType.string_: write(obj.str); break;
        case ShellObjectType.array: write("???ARRAY???"); break;
        case ShellObjectType.obj: write("???OBJECT???"); break;
        case ShellObjectType.func: write(obj.funcName); break;
        case ShellObjectType.noArgStringFunc: write(obj.noArgStringFuncPtr()); break;
        }
    }
}
/*
void echoCommandIfEnabled(scope const(char[])[] args)
{
    //writefln("echoCommands = '%s'", globalSysVars["echoCommands"]);
    const echoCommands = globalSysVars["echoCommands"];
    if (echoCommands.type == ShellObjectType.string_ && echoCommands.str == "1")
        writeln("+ ", args);
}
*/
void echoCommandIfEnabled(ShellObject[] objs)
{
    //writefln("echoCommands = '%s'", globalSysVars["echoCommands"]);
    const echoCommands = globalSysVars["echoCommands"];
    if (echoCommands.type == ShellObjectType.string_ && echoCommands.str == "1")
    {
        write("+ ");
        writeCommand(objs);
        writeln();
    }
}

void executeCommand(ShellObject[] args)
{
    auto result = tryExecuteCommand(args);
    if (result != 0)
    {
        exit(result);
        assert(0);
    }
}
int tryExecuteCommand(ShellObject[] objs)
{
    if (objs.length == 0)
        return 0;

    echoCommandIfEnabled(objs);
    auto redirects = Redirects(stdout, stderr);
    objs = parseRedirect(objs, &redirects);
    if (objs.length == 0)
        assert(0, errorf("got a redirect with no command?"));

    if (objs[0].type == ShellObjectType.func)
        return objs[0].funcPtr(objs[1 .. $], &redirects);

    if (objs[0].type == ShellObjectType.string_)
    {
        auto builtinCommand = tryLookupBuiltinCommand(objs[0].str);
        if (builtinCommand)
            // TODO: do I need to close redirects if they aren't stdout/stderr?
            return builtinCommand(objs[1 .. $], &redirects);
    }

    auto args = objectsToStrings(objs);
    typeof(spawnProcess(args)) result;
    try
    {
        result = spawnProcess(args, stdin, redirects.out_, redirects.err);
    }
    catch (ProcessException e)
    {
        errorf("failed to execute: %s: %s", args, e.msg);
    }
    return wait(result);
}

string[] objectsToStrings(ShellObject[] objs)
{
    auto args = appender!(string[])();
    objectsToStringsInto(objs, &args);
    return args.data;
}
void objectsToStringsInto(ShellObject[] objs, Appender!(string[])* args)
{
    foreach (obj; objs)
    {
        final switch(obj.type)
        {
        case ShellObjectType.string_:
            args.put(obj.str);
            break;
        case ShellObjectType.array:
            objectsToStringsInto(obj.array, args);
            break;
        case ShellObjectType.obj:
            assert(0, errorf("how do you convert an object to a string?"));
        case ShellObjectType.func:
            assert(0, errorf("how do you convert a function to a string (name=%s)?", obj.funcName));
        case ShellObjectType.noArgStringFunc:
            args.put(obj.noArgStringFuncPtr());
        }
    }
}

struct IfState
{
    enum BlockType { if_, elif, else_ }
    BlockType currentBlockType;
    bool currentBlockTrue;
    bool elseEnabled;
    void enterElse()
    {
        if (currentBlockType == BlockType.else_)
            errorf("multiple consecutive 'else' blocks");
        this.currentBlockTrue = elseEnabled;
        this.currentBlockType = BlockType.else_;
    }
}

// Note: comment has already been removed
bool hasArgs(T)(LimitArray!T str)
{
    foreach (c; str)
    {
        if (c != ' ')
            return true;
    }
    return false;
}

bool isCurrentBlockDisabled()
{
    return Script.current.ifStack.length > 0 && !Script.current.ifStack[$-1].currentBlockTrue;
}

// Assumption: line does not start with whitespace
// Returns: true if it was a conditional
bool handleConditionals(LimitArray!char line)
{
    if (line.empty)
        return false;

    auto progStart = line.ptr;
    auto rest = line;
    until(&rest, ' ');
    auto prog = progStart[0 .. rest.ptr - progStart];

    if (prog == "if")
    {
        if (isCurrentBlockDisabled)
            Script.current.ifStack ~= IfState(IfState.BlockType.if_, false, false);
        else
        {
            const result = tryExecuteCommand(rest.splitAndExpand);
            const isTrue = (result == 0);
            Script.current.ifStack ~= IfState(IfState.BlockType.if_, isTrue, !isTrue);
        }
    }
    else if (prog == "elif")
    {
        if (Script.current.ifStack.length == 0)
            errorf("found 'elif' without matching 'if'");
        if (Script.current.ifStack[$-1].elseEnabled)
        {
            const result = tryExecuteCommand(rest.splitAndExpand);
            const isTrue = (result == 0);
            if (isTrue)
                Script.current.ifStack[$-1].elseEnabled = false;
            Script.current.ifStack[$-1].currentBlockTrue = isTrue;
        }
        else
        {
            Script.current.ifStack[$-1].currentBlockTrue = false;
        }
        Script.current.ifStack[$-1].currentBlockType = IfState.BlockType.elif;
    }
    else if (prog == "else")
    {
        if (hasArgs(rest))
            errorf("the 'else' directive does not accept any arguments");
        if (Script.current.ifStack.length == 0)
            errorf("found 'else' without matching 'if'");
        Script.current.ifStack[$-1].enterElse();
    }
    else if (prog == "fi")
    {
        if (hasArgs(rest))
            errorf("the 'fi' directive does not accept any arguments");
        if (Script.current.ifStack.length == 0)
            errorf("found 'fi' without a matching 'if'");
        Script.current.ifStack = Script.current.ifStack[0 .. $-1];
    }
    else
        return false; // not handled
    return true; // handled
}

InternalFunc tryLookupBuiltinCommand(const(char)[] name)
{
    if (name == "exit")   return &exitBuiltin;
    if (name == "assert") return &assertBuiltin;
    if (name == "source") return &sourceBuiltin;
    if (name == "echo")   return &echoBuiltin;
    if (name == "export") return &exportBuiltin;
    if (name == "set")    return &setBuiltin;
    return null;
}
int exitBuiltin(ShellObject[] objs, Redirects* redirects)
{
    auto args = objectsToStrings(objs);

    int exitCode = 1; // default exit code
    if (args.length == 1)
    {
        // TODO: nice error message if not an integer
        exitCode = args[0].to!int;
    }
    else if (args.length != 0)
        assert(0, redirects.errorf("the 'exit' builtin command requires 1 argument, an exit code"));
    exit(exitCode);
    assert(0);
}
int assertBuiltin(ShellObject[] objs, Redirects* redirects)
{
    if (objs.length == 0)
    {
        redirects.errorf("assert");
        assert(0);
    }
    const result = tryExecuteCommand(objs);
    if (result != 0)
    {
        // TODO: print the command!
        redirects.errorf("assert");
        assert(0);
    }
    return 0;
}
int sourceBuiltin(ShellObject[] objs, Redirects* redirects)
{
    auto args = objectsToStrings(objs);
    if (args.length != 1)
        redirects.errorf("the 'source' builtin command requires 1 argument, but got %s", args.length);
    //const filename = buildPath(dirName(Script.current.filename), args[0]);
    const filename = args[0].idup;
    if (!exists(filename))
        redirects.errorf("file '%s' does not exist", filename);
    auto script = Script(filename);
    script.execute();
    return 0;
}
int echoBuiltin(ShellObject[] objs, Redirects* redirects)
{
    auto args = objectsToStrings(objs);
    string prefix = "";
    foreach (arg; args)
    {
        redirects.out_.write(prefix, arg);
        prefix = " ";
    }
    redirects.out_.writeln();
    return 0;
}
int exportBuiltin(ShellObject[] objs, Redirects* redirects)
{
    auto args = objectsToStrings(objs);
    if (args.length != 2)
        redirects.errorf("the 'export' builtin takes 2 arguments");
    environment[args[0].idup] = args[1].idup;
    return 0;
}
int setBuiltin(ShellObject[] objs, Redirects* redirects)
{
    auto args = objectsToStrings(objs);
    if (args.length != 2)
        redirects.errorf("the 'set' builtin takes 2 arguments");
    setvar(args[0].idup, args[1].idup);
    return 0;
}

version (linux)
{
    extern (C) uint getuid();
}
string getuidFunc()
{
    version (linux)
        return getuid().to!string;
    return "?";
}