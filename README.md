# TBDScript (name "To Be Determined")

An alternative to scripting languages like BASH.

# TODO

* functions
```bash
function <name>
# how to end the function?
```
* sources/imports
```bash
import path/myfile.tbdscript
echo $myfile.foo
```
* set options?
```bash
set [mods] var value
set var value
set default var value
set const var value
set default const var value
```
* loops?
* pipes?
* inline expansion `$(...)`?

* arrays
```bash
set foo $[a b c]
echo $foo[0]
echo $foo[1]
echo $foo
```

* stacks
```bash
pushscope
    set x 1
    echo x is $x
popscope
# x is out of scope, no longer defined
```

* defer and errdefer

```bash
pushscope
    touch a
    defer rm a # a will be removed after this scope

    echo "foo" >> a
    echo "bar" >> a
popscope
```

```bash
pushscope
    errdefer rm a.out # a.out will be removed if this scope fails
    gcc hello.c
popscope
```

# Features

* Builtin commands

```bash
# echo to the console
echo <args>...

# include a file
source <filename>

# set a local variable
set <name> <value>

# set an environment variable
export <name> <value>

# exits the script with the given code
exit <code>

# exits the script and prints a message if the given command fails.
# always fails if not command is given
assert [<command>...]
```

* Variable Substition

```bash
echo foo is $foo
echo foo-bar is ${foo}-$bar

# with some 'sys' variables
echo this file is $sys.file and lives in $sys.abs_dir
```

* Conditionals
```bash
if true
    if false
        echo "Error: false is true"
        assert
    else
        echo "A nested if-else"
    fi
elif true
    echo "Error: true was false, not it's true?"
    assert
else
    echo "Error: true is false?"
    assert
fi
```

* Quoted Strings

```bash
# quoted strings allow arguments with whitespace
cat "a file with whitespace.txt"

# escape quotes inside strings with two quote characters
echo "escape quotes "" with two of them"

# use quotes when you want to include a comment '#' charater
echo "printing a comment # character"
```

* Line Continuation

```bash
echo line \
    continuation

even "works even\
 inside quotes"
```

* Redirection

```bash
echo "hello" > testfile
echo "hello" 2> testfile
echo "hello" &> testfile
echo "hello" >> testfile
echo "hello" 2>> testfile
echo "hello" &>> testfile
```

* Verbose Output

```bash
set sys.printCommands 1
```

# Processing steps

In order to understand the subtleties of the syntax, it can be very helpful to understand how the script is processed.  TBDScript performs each step in isolation which makes it easier to understand what it will do so long as you understand the order.

1. line continuation
2. strip whitespace from the ends
3. handle if/elif/else/fi
4. split and expand
    - split up arguments by whitespace except within quoted string
    - expand `$` expressions
5. detect and setup redirection
6. check if it's a builtin command

`exit`, `assert`, `source`, `echo`, `export`, `set`

7. if not a builtin, execute it as an external program

### The finer points

Since "line continuation" is the first step, it always works.  Even inside quotes.
```bash
echo line \
    continuation

even "works even\
 inside quotes"
```

The conditional commands `if/elif/else/fi` are handled before expansion.  This is so that expansion doesn't have to be done if it isn't necessary.

There are 2 reasons to use "quoted strings"

1. If you want to specify an argument that includes whitespace.
2. If you want to include a `#` or `"` character in your arguments.

Quoted strings can include the `"` character by using 2 of them, i.e.
```
echo "This is a quote "" inside a quoted string"
```
