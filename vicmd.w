% qcar 2013 2014 -- first attempt at literate programming

\nocon % omit table of contents
% \datethis % print date on listing
\def\bull{\item{$\bullet$}}
\def\ASCII{{\sc ASCII}}
@f line x
@f Rune int
@f W int
@f EBuf int

@ This module provides an implementation of \.{vi} commands.  We try to
provide an implementation roughly \.{POSIX} compliant of the \.{vi} text
editor.  The only important function exported by this module accepts
unicode runes and parses them to construct commands, these commands are
then executed on the currently focused window.  We try to follow the
\.{POSIX} standard as closely as a simple implementation allows us.

@c
@<Header files to include@>@/
@<Helpful macros@>@/
@<External variables and functions@>@/
@<Local types@>@/
@<Predeclared functions@>@/
@<File local variables@>@/
@<Subroutines and commands@>@/
@<Definition of the parsing function |cmd_parse|@>

@ We need to edit buffers, have the rune and window types available.
This module header file is also included to allow the compiler to check
consistency between definitions and declarations.  For debugging
purposes we also include \.{stdio.h}.

@<Header files...@>=
#include <assert.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include "unicode.h"
#include "buf.h"
#include "edit.h"
#include "gui.h"
#include "win.h"
#include "exec.h"
#include "cmd.h"

@ To make happy modern versions of GCC we have to use some macro
or attribute to mark unused variables, for example in m\_match()
and yank(). Otherwise it will yell with annoying warnings.

@<Helpful macros@>=
#define UNUSED(__var) \
	(void) (__var)

@ The \.{vi} editor is modal so we must keep track of the current
mode we are currently into.  When the editor starts it is in
command mode.

@<File local variables...@>=
enum {
	Command = 'c',
	Insert = 'i'
};
int mode = Command;


@** Parsing of commands. We structure the parsing function as a
simple state machine.  The state must be persistent across function
calls so we must make it static.  Depending on the rune we just
got, this state needs to be updated.  Errors during the state
update are handled by a |goto err| statement which resets the
parsing state and outputs an error message.

@<Definition of the parsing fun...@>=
void
cmd_parse(Rune r)
{
	@<Initialize the persistent state of |cmd_parse|@>;
	switch (mode) {
	case Insert: insert(r); @+break;
	case Command: @<Update parsing state@>; @+break;
	}
	return;
err:	puts("! invalid command");
@.invalid command@>
	@<Reset parsing state@>;
}


@ Usual \.{vi} commands will consist of at most four parts described
below.

\yskip\bull The buffer---which can be any latin letter or digit---on which
	the command should act.  A buffer can be specified by starting
	with a \." character.
\bull The count which indicates how many times a command needs to
	be performed. We have to be careful here because there is a
	special case: \.0 is a command.
\bull The actual main command character which can be almost any letter.
	Some commands require an argument, for instance the \.m command.
\bull An optional motion that is designating the area of text on
	which the main command must act. This motion is also a command
	and can have its own count and argument.

\yskip\noindent The structure defined below is a ``light'' command which
cannot store a motion component.  We make this choice to permit
factoring of the data structures. A complex command will be composed
of two such structures, one is the main command, the other is the
motion command.


@<Local typ...@>=
typedef struct {
	unsigned short count;
	unsigned char chr;
	Rune arg;
} Cmd;

@ @<Initialize the pers...@>=
static char buf;
static Cmd c, m, *pcmd = &c;
static enum {
	BufferDQuote,	/* expecting a double quote */
	BufferName,	/* expecting the buffer name */
	CmdChar,	/* expecting a command char or count */
	CmdDouble,	/* expecting the second char of a command */
	CmdArg		/* expecting the command argument */
} state = BufferDQuote;

@ Updating the |cmd_parse| internal state is done by looking first
at our current state and then at the rune |r| we were just given.
If the input rune is |GKEsc| we cancel any partial parsing by
resetting the state.

@<Update pars...@>=
if (r == GKEsc) @<Reset pars...@>@;
else
	@+switch (state) {
	case BufferDQuote: @<Get optional double quote@>; @+break;
	case BufferName: @<Input current buffer name@>; @+break;
	case CmdChar: @<Input command count and name@>; @+break;
	case CmdDouble: @<Get the second character of a command@>; @+break;
	case CmdArg: @<Get the command argument@>; @+break;
	default: abort();
	}

@ When parsing a command, one buffer can be specified if the double
quote character is used.  If we get any other rune, we directly
retry to parse it as a command character by switching the state
to |CmdChar|.

@<Get optional double quote@>=
if (r == '"')
	state = BufferName;
else {
	state = CmdChar;
	cmd_parse(r);
}

@ Buffer names cannot be anything else than an \ASCII\ letter or
a digit.  If the rune we got is not one of these two we will
signal an error and abort the current command parsing.

@d risbuf(r) (risascii(r) && (islower(r) || isdigit(r)))

@<Input current buffer name@>=
if (!risbuf(r)) goto err;
buf = r;
state = CmdChar;

@ When a double character command is expected we ensure that the
second character received is the same as the first and resume
the processing performed in |@<Input command count...@>|.

@<Get the second char...@>=
if (r != pcmd->chr)
	goto err;
goto gotdbl;

@ @<Get the command arg...@>=
pcmd->arg = r;
goto gotarg;

@ The |CmdChar| state needs to handle both the count and the command
name.  Depending on the command kind (double char, expecting an
argument, ...) we have to update the state differently.  To get this
information about the command we use the array of flags |keys|.

@<Input command count and name@>=
if (!risascii(r)) goto err;

if (isdigit(r) && (r != '0' || pcmd->count)) {
	pcmd->count = 10 * pcmd->count + (r - '0');
} else {
	if (pcmd->count == 0)
		pcmd->count = !(keys[r].flags & CZeroCount);
	pcmd->chr = r;
	if (keys[pcmd->chr].flags & CIsDouble) {
		state = CmdDouble; @+break;
	}
gotdbl:
	if (keys[pcmd->chr].flags & CHasArg) {
		state = CmdArg; @+break;
	}
gotarg:
	if (pcmd == &m && !(keys[pcmd->chr].flags & CIsMotion))
		goto err;
	if (keys[pcmd->chr].flags & CHasMotion) {
		assert(pcmd == &c);
		pcmd = &m; @+break;
	}
	docmd(buf, c, m);
	@<Reset parsing state@>;
}

@ The internal state is reset by zeroing the |count| field of the
commands, this is necessary since |@<Input command count...@>| relies
on it to determine if a received |'0'| is part of the count or is the
command name.  We also need to change the state back to |BufferDQuote|.

@<Reset parsing state@>=
{	m.count = c.count = 0;
	buf = 0;
	pcmd = &c;
	state = BufferDQuote;
}

@ The |keys| table contains a set of flags used to specify the proper
parsing and interpretation of each \.{vi} command.  It also contains
a description of the action to take, we postpone its definition for
later. Since the \.{vi} commands are \ASCII\ characters so the table
only needs 128 entries.

@d CIsDouble 1 /* is the command a double character command */
@d CHasArg 2 /* is the command expecting an argument */
@d CHasMotion 4 /* is the command expecting a motion */
@d CIsMotion 8 /* is this a motion command */
@d CZeroCount 16 /* can this motion have a 0 count */

@<File local variables...@>=
static struct {
	int flags;
	@<Other key fields@>@;
} keys[128] = { @<Key definitions@> };


@** Execution of the parsed commands. The commands act on the active
window.  This window is accessible via a global program variable.

@d curb (&curwin->eb->b) /* convenient alias for the current buffer */

@<External...@>=
extern W *curwin;
void chwin(W *);

@* Insertion mode.  Insertions can be replayed---either using a count or
using the repeat command---so we keep track of all the typed runes in the
local buffer |lasti|.  External code can set |cnti| to repeat the inserted
text |cnti-1| times when the insertion mode is exited.

@d MaxInsert 512

@<File local...@>=
static struct {
	Rune buf[MaxInsert];
	unsigned len;
	int locked;
} lasti;
static unsigned short cnti;

@ Before inserting we must make sure that the state is consistent and
reset the |lasti| buffer if allowed.

@<Switch to insertion mode@>=
if (!lasti.locked)
	lasti.len = 0;
cnti = 1;
mode = Insert;

@ The insertion function is in fact a simple interpreter for an editing
language where commands are runes.  Most runes are simply inserted
directly in the buffer but some runes need a special action, for example,
they can delete one character or adjust the indentation.  To be able to
replay an insertion we memorize the typed runes in the |lasti| buffer.
Since this buffer is fixed size we cancel the recording when the insertion
is too long.

@<Sub...@>=
static void insert(Rune r)
{
	if (!lasti.locked && r != GKEsc) {
		if (lasti.len < MaxInsert)
			lasti.buf[lasti.len++] = r;
		else
			lasti.len = 0, lasti.locked = 1;
	}

	switch (r) {
	case GKEsc: @<Repeat insert |cnti-1| times; leave insert mode@>; @+break;
	case GKBackspace: @<Delete one character@>; @+break;
	case '\n': @<Insert a new line preserving the indentation@>; @+break;
	default: eb_ins(curwin->eb, curwin->cu++, r); @+break;
	}
}

@ When we are about to switch from insertion to command mode, we mark the
buffer as being in a clean state by committing it.  This will add the finished
insertion into the modification log used to undo changes.

@<Repeat insert...@>=
lasti.locked = 1;
assert(cnti != 0);
while (--cnti)
	for (unsigned u = 0; u < lasti.len; u++)
		insert(lasti.buf[u]);
lasti.locked = 0;

if (buf_get(curb, curwin->cu-1) != '\n')
	curwin->cu--;
eb_commit(curwin->eb), mode = Command;

@ @<Delete one char...@>=
if (curwin->cu > 0) {
	eb_del(curwin->eb, curwin->cu-1, curwin->cu);
	curwin->cu--;
}

@ @d risblank(r) (risascii(r) && isblank(r))
@<Insert a new line...@>=
eb_ins(curwin->eb, curwin->cu, '\n');
for (
	unsigned p = buf_bol(curb, curwin->cu++);
	r = buf_get(curb, p), risblank(r);
	p++
)
	eb_ins(curwin->eb, curwin->cu++, r);

@* Motion commands. They can be used as parameters for destructive commands,
they almost always have two semantics, one when they are used bare
to move the cursor and one when they are used as parameter.  All motion
commands implemented below will return 0 if they succeed and 1 if they fail.

%
% TODO Fix the vocabulary issues, motion command/parameter, etc...
%      Hint, fit to posix
%

The motion functions defined take as argument an integer that specifies
if they are called as motion parameters or not.  Depending on this argument
the \Cee\ structure describing the motion to perform will be filled
differently.  If called as a motion parameter, the |beg| and |end| fields
will contain the region defined by the motion; otherwise, only the |end|
field will be relevant and it will store the final cursor position.  If the
function returns 1, the motion structure should not be used.

The structure also contains the following set of flags.

\yskip\bull |linewise| indicates if the motion operates on full lines or on characters.
	At first sight this is more related to the motion command
	than the motion result, so it should be in |keys| rather than in
	this structure.  But this would not be precise enough: The standard mandates
	that certain commands, depending on the invocation context, give linewise or
	character wise motions.  This is for instance the case for \.\}.

\yskip\noindent When a motion command is called, |beg| is set to the current cursor
postion and flags are zeroed.

@<Local typ...@>=
typedef struct {
	unsigned beg, end;
	int linewise : 1;
} Motion;

@ Motion commands often need to skip blanks, for instance, to find the first
non blank character of a line.  The following function will be of great help
with this.  It finds the end of a blank span starting at position |p|.

@<Subr...@>=
static unsigned blkspn(unsigned p)
{
	Rune r;
	do r = buf_get(curb, p++); while (risblank(r));
	return p-1;
}

@ The most elementary cursor motions in \.{vi} are \.h \.j \.k and \.l.
We must note that the \.{POSIX} specification mandates a subtle difference
of behaviors between vertical and horizontal motions.  When a count
is specified, the horizontal motion must succeed even if the count is
too big while vertical motions must fail in this case.  In this
implementation files do not end, so a vertical motion towards the end of
the buffer will always succeed.

@d swap(p0, p1) { unsigned _tmp = p0; p0 = p1, p1 = _tmp; }

@<Predecl...@>=
static int m_hl(int, Cmd, Motion *);
static int m_jk(int, Cmd, Motion *);

@ One special case needs to be handled for \.l here: If the cursor is
on the last column of the line and the command is called as a motion
command, the range selected is the last character of the line; however
if the command is not called as a motion command we must signal an
error.  This funny behavior contributes to what makes me think that
\.{vi}'s language is not as algebraic as it might appear at first
and maybe needs some revamp.

@<Subr...@>=
static int m_hl(int ismotion, Cmd c, Motion *m)
{
	int line, col;
	buf_getlc(curb, m->beg, &line, &col);
	if (c.chr == 'h') {
		if (col == 0) return 1;
		m->end = buf_setlc(curb, line, col - c.count);
		if (ismotion) swap(m->beg, m->end);
	} else {
		if (buf_get(curb, m->beg) == '\n') return 1;
		m->end = buf_setlc(curb, line, col + c.count);
		if (!ismotion && buf_get(curb, m->end) == '\n') return 1;
	}
	return 0;
}

@ For vertical motions, be careful to signal an error if the motion hits
the top of the buffer.

@<Subr...@>=
static int m_jk(int ismotion, Cmd c, Motion *m)
{
	int line, col;
	buf_getlc(curb, m->beg, &line, &col);
	if (c.chr == 'k') {
		if (c.count > line) return 1;
		m->end = buf_setlc(curb, line - c.count, col);
	} else
		m->end = buf_setlc(curb, line + c.count, col);
	if (ismotion) {
		if (c.chr == 'k') swap(m->beg, m->end);
		@<Extend the motion range to lines@>;
	}
	return 0;
}

@ Linewise motions have to be extended to range over full lines,
they include the last newline character.

@<Extend the motion range to lines@>=
{
	m->linewise = 1;
	m->beg = buf_bol(curb, m->beg);
	m->end = buf_eol(curb, m->end) + 1;
}

@ Another family of useful and easy to implement motions are the line
oriented motions.  We start by implementing character lookup motions,
there are four commands of this kind \.t, \.f, \.T and \.F.  Uppercase
commands search backwards, lowercase run forward.

@<Subr...@>=
static int m_find(int ismotion, Cmd c, Motion *m)
{
	int dp = islower(c.chr) ? 1 : -1;
	unsigned p = m->beg;
	register Rune r;

	@<Save the searched rune and the command name@>;
	while (c.count--)
		while ((r = buf_get(curb, p += dp)) != c.arg)
			/* |buf_get| must return |'\n'| at position |-1u| */
			if (r == '\n') return 1;

	m->end = tolower(c.chr) == 'f' ? p : p-dp;
	if (ismotion) {
		if (dp == 1) m->end++;
		else swap(m->beg, m->end);
	}
	return 0;
}

@ The two commands \., and \.; repeat the last character search
motion.  So we need to store the searched rune and the command
name in a file local structure at each invocation of |m_find|.
This structure can be locked to prevent |m_find| from altering
it in certain special conditions.  The lock is used in the
implementation of the undo and the ``repeat find'' commands.

@<File local vari...@>=
static struct {@+char locked;@+char chr;@+Rune arg;@+} lastf;

@ @<Save the searched rune...@>=
if (!lastf.locked) lastf.chr = c.chr, lastf.arg = c.arg;
else lastf.locked = 0; // reset the lock

@ The \.; command repeats the last search in the same direction,
while \., inverts the direction.  We must take care of locking
the |lastf| structure to avoid an alternating behavior when
using the \., command repeatedly.

@<Subr...@>=
static int m_repf(int ismotion, Cmd c, Motion *m)
{
	Cmd cf = {c.count, lastf.chr, lastf.arg };

	if (lastf.chr == 0) return 1;
	if (c.chr == ',') cf.chr ^= 32; // flip case
	lastf.locked = 1;
	return m_find(ismotion, cf, m);
}


@ @<Predecl...@>=
static int m_find(int, Cmd, Motion *);
static int m_repf(int, Cmd, Motion *);

@ The \.{vi} command set provides two commands to move towards the
beginning of the line: \.0 and \.\^.  The latter moves to the first
non-blank character in the line while the former will move in the
first column, both commands do not accept a count and fail if used
as motion commands and do not move the cursor.

@<Subr...@>=
static int m_bol(int ismotion, Cmd c, Motion *m)
{
	m->end = buf_bol(curb, m->beg);
	if (c.chr == '^') m->end = blkspn(m->end);
	if (ismotion && m->end < m->beg) swap(m->beg, m->end);
	return ismotion && m->end == m->beg;
}

@ The \.\$ command moves to the end of line.  This command accepts
a count argument to move to the end of the $n$-th line after the
current one.  Note that it can be a linewise motion depending on
the initial cursor position.

@<Subr...@>=
static int m_eol(int ismotion, Cmd c, Motion  *m)
{
	unsigned bol = buf_bol(curb, m->beg);
	int l, x;


	buf_getlc(curb, m->beg, &l, &x);
	m->end = buf_eol(curb, buf_setlc(curb, l + c.count - 1, 0)) - 1;
	if (ismotion || buf_get(curb, m->end) == '\n') m->end++;
	if (ismotion && c.count > 1 && blkspn(bol) >= m->beg)
		m->linewise = 1, m->beg = bol, m->end++;

	return ismotion && c.count == 1 && m->end == m->beg;
}

@ The \.\_ command is handy to select the current line in full.
Here I rely on the fact that \.j can be called with 0 as count and
selects the current line if run as motion in this case.

@<Subr...@>=
static int m_line(int ismotion, Cmd c, Motion *m)
{
	int r = m_jk(ismotion, (Cmd){ c.count-1, 'j', 0 }, m);
	if (ismotion || r) return r;
	m->end = blkspn(buf_bol(curb, m->end));
	return 0;
}

@ @<Predecl...@>=
static int m_bol(int, Cmd, Motion *);
static int m_eol(int, Cmd, Motion *);
static int m_line(int, Cmd, Motion *);

@ Next, we implement word motions.  They can act on {\sl big} or
{\sl small} words.  Small words are sequences composed of alphanumeric
characters and the underscore \_ character.  Big words characters
are anyting that is not a space.  We will need two predicate functions
to recognize these two classes of characters.

@<Subr...@>=
static int risword(Rune r)
{
	return (risascii(r) && isalpha(r)) /* \ASCII\ alpha */
	    || (r >= 0xc0 && r < 0x100) /* attempt to detect
	                                   latin characters */
	    || (r >= '0' && r <= '9')
	    || r == '_';
}

static int risbigword(Rune r)
{
	return !risascii(r) || !isspace(r);
}

@ Word motions involve some kind of light parsing.  Since the buffer
implementation exposes infinite buffers we have to take care of
not hanging in a loop when going towards the end of the buffer.
To do this we rely on the |limbo| field of the \Cee\ buffer structure.
This field contains the offset at which limbo begins, the motion stops
as soon as it gets past this offset.

We use the following regular grammars to factor the code for the four
forward word motion commands.
$$
\vbox{\halign{\hfil#: &# \cr
\.w / \.W& $in^*; (\neg in)^+; in$ \cr
\.e / \.E& $(\neg in)^*; in^+; \neg in$ \cr
}}
$$
In the above figure, $in$ matches a big or small word rune (depending
on the command we implement).  The second grammar matches one rune
past the end of the next word.  I compiled these two grammars in
a deterministic automaton.  Since one grammar above is mapped to the
other by changing $in$ to $\neg in$, we only need to store one
automaton.

@<Predecl...@>=
static int m_ewEW(int, Cmd, Motion *);
static int m_bB(int, Cmd, Motion *);


@ There is a special case for \.w and \.W as motion commands.  They do
not delete newlines after the last word scanned, this is addressed
by the second test used for early exit.

@<Subr...@>=
static int m_ewEW(int ismotion, Cmd c, Motion *m)
{
	int @[@] (*in)(Rune) = islower(c.chr) ? risword : risbigword;
	int dfa[][2] = {{1, 0}, {1, 2}}, ise = tolower(c.chr) == 'e' ;
	unsigned p = m->beg;
	Rune r = 'x';

	while (c.count--)
		for (
			int s = 0;
			s != 2;
			s = dfa[s][ise ^ in(r = buf_get(curb, ise + p++))]
		) {
			if (p >= curb->limbo + 1) break;
			if (r == '\n' && c.count == 0 && ismotion && !ise) break;
		}
	m->end = ismotion && ise ? p : p-1;
	return 0;
}

@ The backward word motion commands are implemented with the same
technique.

@<Subr...@>=
static int m_bB(int ismotion, Cmd c, Motion *m)
{
	int @[@] (*in)(Rune) = c.chr == 'b' ? risword : risbigword;
	int dfa[][2] = {{0, 1}, {2, 1}};
	unsigned p = m->beg;

	while (c.count--)
		for (
			int s = 0;
			s != 2 && p != -1u;
			s = dfa[s][in(buf_get(curb, --p))]
		);
	m->end = p+1;
	if (ismotion) swap(m->beg, m->end);
	return 0;
}

@ Paragraph motions \.\{ and \.\} are implemented next.  We recognize
consecutive blank lines and form feed characters as paragraph
separators.  Special care must be taken when these commands are used
as motion commands because they can be linewise or not: If the cursor
is at the beginning of a line on a blank character the motion is
linewise, otherwise it is not.

I will ignore all legacy features related to \.{nroff} editing since,
today, I prefer \TeX\ over it.  If you desperately need them, they are
easy to hack in (just treat them as form feeds).

@<Subr...@>=
static int m_par(int ismotion, Cmd c, Motion *m)
{
	int l, x, dl = c.chr == '{' ? -1 : 1;
	enum {@+Blank, FormFeed, Text@+} ltyp;
	int s, dfa[][3] = {
		{ 0, 3, 3 },
		{ 2, 2, 3 },
		{ 2, 9, 3 },
		{ 9, 9, 3 }
	};
	unsigned bol;

	buf_getlc(curb, m->beg, &l, &x);
	bol = buf_bol(curb, m->beg);
	@<Detect if paragraph motion is linewise@>;

	while (c.count--)
		for (
			s = c.chr == '{';
			l >= 0 && (bol < curb->limbo || c.chr == '{');
		) {
			@<Set |ltyp| to the line type of the current line@>;
			@<Update the state |s| and proceed to the next line@>;
		}

	m->end = bol;
	if (ismotion && c.chr == '{') swap(m->beg, m->end);
	return 0;
}

@ @<Set |ltyp|...@>=
switch (buf_get(curb, blkspn(bol))) {
case '\n': ltyp = Blank;@+break;
case '\f': ltyp = FormFeed;@+break;
default: ltyp = Text;@+break;
}

@ The only critical point when updating the state and moving on to
the next line is to check if the final state is reached before
updating |bol|.  If we do not respect this order the implementation
is off by one line.

@<Update the state |s| and...@>=
if ((s = dfa[s][ltyp]) == 9) break;
l += dl, bol = buf_setlc(curb, l, 0);

@ A paragraph motion is linewise when the cursor is at or before the
first non-blank rune of the line.  In this case, we change |m->beg| to
point to the very first character (blank or not) of the line so the
motion command acts on full lines.  This behavior conforms to Keith
Bostic's \.{nvi} for the forward paragraph motion but differs for the
backward motion.  I feel like the difference made little sense and
unified the two.

@<Detect if para...@>=
if (blkspn(bol) >= m->beg) {
	m->beg = bol;
	m->linewise = 1;
}

@ Next comes the \.\% motion that finds the matching character.
We simply use the algorithm described in the \.{POSIX} standard and
maintain a counter of the nesting level of the considered delimiters.

@<Subr...@>=
static int m_match(int ismotion, Cmd c, Motion *m)
{
	Rune match[] = { '<', '{', '(', '[', ']', ')', '}', '>' };
	int n, dp, N = sizeof match / sizeof match[0];
	unsigned p = m->beg;
	Rune beg, end, r;
	UNUSED(c);

	@<Find the search direction and the matching character@>;
	for (
		n = 0;
		(n += (r == beg) - (r == end)) != 0;
		r = buf_get(curb, p += dp)
	)
		if (p == -1u || p >= curb->limbo) return 1;
	m->end = p;
	if (ismotion)
		@<Detect if the motion is linewise and adjust it@>;
	return 0;
}

@ The move to matching character command looks for the first valid
delimiter after the cursor position in the line.  If no such
delimiter is found we signal an error.

@<Find the sear...@>=
for (; (r = beg = buf_get(curb, p)) != '\n'; p++)
	for (n = 0; n < N; n++)
		if (match[n] == r) goto found;
return 1;
found: dp = n >= N/2 ? -1 : 1, end = match[N - n - 1];

@ The motion is linewise if only blank characters are before the
opening delimiter and after the closing delimiter, this is
convenient for programming languages with blocks like C.

@<Detect if the motion is line...@>=
{
	if (dp == -1) swap(m->beg, m->end);
	m->end++; // get past the closing delimiter
	if (blkspn(buf_bol(curb, m->beg)) >= m->beg
	&& blkspn(m->end) == buf_eol(curb, m->end))
		@<Extend the motion range...@>;
}

@ @<Predecl...@>=
static int m_par(int, Cmd, Motion *);
static int m_match(int, Cmd, Motion *);

@ The \.G command moves to a line specified by its count, if no count
is given, the cursor is moved to limbo.  When used as a motion command,
the text copied must always be in line mode.

@<Subr...@>=
static int m_G(int ismotion, Cmd c, Motion *m)
{
	m->end = c.count ? buf_setlc(curb, c.count-1, 0) : curb->limbo;
	if (!ismotion)
		m->end = blkspn(m->end);
	else {
		if (m->end < m->beg) swap(m->beg, m->end);
		@<Extend the motion range...@>;
	}
	return 0;
}

@ The \.H, \.L, and \.M motions are relative to the screen, the motion
destination depends on the screen contents.  We get this information
using the window module.  Older implementations used the buffer contents
and counted newlines, this did not work well with line wrapping and
would be a real mess with variable width font.

@<Subr...@>=
static int m_HML(int ismotion, Cmd c, Motion *m)
{
	if ((c.chr == 'H' || c.chr == 'L')
	&& c.count > curwin->nl)
		return 1;
	switch (c.chr) {
	case 'H':
		m->end = curwin->l[c.count-1];
		@+break;
	case 'L':
		m->end = curwin->l[curwin->nl-c.count];
		@+break;
	case 'M':
		m->end = curwin->l[curwin->nl/2];
		@+break;
	}
	if (ismotion) {
		if (m->end < m->beg) swap(m->beg, m->end);
		@<Extend the motion range...@>;
	}
	return 0;
}

@ @<Predecl...@>=
static int m_G(int, Cmd, Motion *);
static int m_HML(int, Cmd, Motion *);

@ Jumping to a given mark in the buffer can be done using either
\.' or \.`.  Marks are inserted in the buffer with the \.m command.
The \.' motion is a line motion and lands on the first non-blank
character of the marked line; \.` is its character-wise counterpart.

@<Subr...@>=
static int m_mark(int ismotion, Cmd c, Motion *m)
{
	if ((m->end = eb_getmark(curwin->eb, c.arg)) == -1u)
		return 1;
	if (ismotion) {
		if (m->end < m->beg) swap(m->beg, m->end);
		if (c.chr == '\'') @<Extend the motion range...@>;
	}
	else if (c.chr == '\'')
		m->end = blkspn(buf_bol(curb, m->end));
	return 0;
}

@ @<Predecl...@>=
static int m_mark(int, Cmd, Motion *);

@ The search functionality in this editor differs pretty drastically from
\.{vi}'s historical behavior.  Search is triggered by the \.n command
only.  The string searched can be set using the built-in \.{Look}
command, otherwise the selection is searched or, as a last resort,
the annonymous yank buffer.  When a match is found the selection
is set to the matched text.  If the search hits limbo it wraps around.

@<Subr...@>=
static int m_nN(int ismotion, Cmd c, Motion *m)
{
	YBuf b = {0, 0, 0, 0}, *pb = &yannon;
	int err = 0;
	unsigned s0, s1;

	s0 = eb_getmark(curwin->eb, SelBeg);
	s1 = eb_getmark(curwin->eb, SelEnd);
	if (s0 < s1 && s0 != -1u && s1 != -1u)
		eb_yank(curwin->eb, s0, s1, pb = &b);
	while (c.count--)
		err |= ex_look(curwin, pb->r, pb->nr, c.chr == 'N');
	free(b.r);
	m->end = curwin->cu;
	if (ismotion)
		@<Extend the motion range...@>;
	return err;
}

@ @<Predecl...@>=
static int m_nN(int, Cmd, Motion *);

@ Because the search functionality is different, the \./ command is free
to use.  We reuse it as a motion that designates the whole selection.
This way, it is easy to delete or change a selected region using regular
\.{vi} commands.

@<Subr...@>=
static int m_sel(int ismotion, Cmd c, Motion *m)
{
	if (!ismotion || c.count != 1) return 1;
	m->beg = eb_getmark(curwin->eb, SelBeg);
	m->end = eb_getmark(curwin->eb, SelEnd);
	return m->beg >= m->end || m->end == -1u;
}

@ @<Predecl...@>=
static int m_sel(int, Cmd, Motion *);

@*1 Hacking the motion commands. Here is a short list of things you
want to know if you start hacking either the motion commands, or any
function used to implement them.

\yskip\bull Functions on buffers must be robust to funny arguments.  For
	instance in |m_hl| we rely on the fact that giving a negative
	column as argument to |buf_setlc| is valid and returns the offset
	of the first column in the buffer.  Dually, if the column count
	is too big we must get into the last column which is the one
	containing the newline character |'\n'|.

\bull Lines and columns are 0 indexed.

\bull All lines end in |'\n'|.  This must be guaranteed by the buffer
	implementation.

\bull Functions dealing with lines (|buf_bol|, |buf_eol|, ...) must count
	the trailing |'\n'| as part of the line. So, by the previous point,
	an empty line consists only of a newline character which marks its
	end.

\bull Files do not end.  There is an (almost) infinite amount of newline
	characters at the end.  This part is obviously not stored in
	memory, it is called {\sl limbo}.  Deletions in limbo must work
	and do nothing.

@* Edition commands.  Contrary to motion commands these ones act
on the buffer to insert and delete text.  We have to be careful to
commit the modifications after each successful execution of a command
so that the undo command behaves properly.  Like motion commands, an
error code is returned by edition commands, 0 significates success while
1 indicates an error.

@ Any command altering some text lets the user specify a yank buffer used
to store the deleted text.  In addition to this, the text is stored in
the annonymous buffer and, for deletions spanning over multiple lines, in
the first numeric buffer.  Before yanking in the first numeric buffer,
numeric buffers are shifted: 1 becomes~2, 2 becomes~3, and so on.
Because of this shuffling we represent numeric buffers as a ring.

@<File local var...@>=
static int ytip;
static YBuf ynum[9], yannon;

@ @<Subr...@>=
static void yankspan(Motion *m, YBuf *y)
{
	eb_yank(curwin->eb, m->beg, m->end, y);
	y->linemode = m->linewise;
}

static int yank(Motion *m, char buf, unsigned count, Cmd mc)
{
	UNUSED(buf);
	mc.count *= count;

	*m = (Motion){curwin->cu,0,0};

	assert(keys[mc.chr].flags & CIsMotion);
	if (keys[mc.chr].motion(1, mc, m))
		return 1;

	if (m->linewise)
		yankspan(m, &ynum[ytip = (ytip + 8) % 9]);
	yankspan(m, &yannon);

	return 0;
}

@ In addition to the original \.{vi}, the yank command sets the text
selection.  The selection mechanism is implemented using two
special buffer marks defined in the edition module.

@<Subr...@>=
static int a_y(char buf, Cmd c, Cmd mc)
{
	Motion m = {0, 0, 0};
	int r = yank(&m, buf, c.count, mc);

	if (r == 0) {
		eb_setmark(curwin->eb, SelBeg, m.beg);
		eb_setmark(curwin->eb, SelEnd, m.end);
	}
	return r;
}

@ Putting text back from buffers is a simple matter of figuring out
which buffer to use.  Depending on the put command used, the text
is inserted after or before the cursor.

@<Subr...@>=
static int a_pP(char buf, Cmd c, Cmd mc)
{
	YBuf *y = &yannon;

	(void)mc;
	if (buf >= '1' && buf <= '9')
		y = &ynum[(ytip + buf - '1') % 9];
	else if (buf != 0) return 1;

	@<Prepare the cursor for putting@>;

	while (c.count--) // copy |y|'s contents
		for (unsigned p=0; p<y->nr; p++)
			eb_ins(curwin->eb, curwin->cu+p, y->r[p]);
	eb_commit(curwin->eb);
	return 0;
}

@ @<Prepare the cursor...@>=
if (y->linemode && c.chr == 'P')
	curwin->cu = buf_bol(curb, curwin->cu);
else if (y->linemode && c.chr == 'p')
	curwin->cu = buf_eol(curb, curwin->cu) + 1;
else if (c.chr == 'p' && buf_get(curb, curwin->cu) != '\n')
	curwin->cu++;

@ The delete and change \.{vi} commands have a similar action expect
that the latter will switch to insertion mode.  If the motion fails,
both change and delete commands also fail.

@<Subr...@>=
static int a_d(char buf, Cmd c, Cmd mc)
{
	Motion m;

	if (c.chr == 'x') mc = (Cmd){1, 'l', 0};
	if (yank(&m, buf, c.count, mc)) return 1;
	eb_del(curwin->eb, curwin->cu = m.beg, m.end);
	eb_commit(curwin->eb);
	return 0;
}

static int a_c(char buf, Cmd c, Cmd mc)
{
	Motion m;

	if (yank(&m, buf, c.count, mc)) return 1;
	if (m.linewise) {
		m.beg = blkspn(m.beg), m.end--;
		assert(buf_get(curb, m.end) == '\n');
	}
	eb_del(curwin->eb, curwin->cu = m.beg, m.end);
	@<Switch to insertion mode@>;
	return 0;
}

@ Editing positions can be memorized in marks, these marks are
updated automatically in case changes occur in the buffer.  All
the bookkeeping is done in the edition module.

@<Subr...@>=
static int a_m(char buf, Cmd c, Cmd mc)
{
	(void)buf; @+(void)mc;
	eb_setmark(curwin->eb, c.arg, curwin->cu);
	return 0;
}

@ The write command simply uses the function exposed by the buffer
module.

@<Subr...@>=
static int a_write(char buf, Cmd c, Cmd mc)
{
	(void)buf; @+(void)c; @+(void)mc;
	return ex_put(curwin->eb, 0);
}

@ @<Subr...@>=
static int a_exit(char buf, Cmd c, Cmd mc)
{
	extern int exiting;
	(void)buf; @+(void)c; @+(void)mc;
	return (exiting = 1);
}

@ Scrolling is a simple matter of calling the window module.
To avoid confusing the cursor management code we signal that
we are scrolling the screen using the global variable
|scrolling|.  This will prevent the editor to adjust the
screen offset if the cursor goes out of view.

@<Subr...@>=
static int a_scroll(char buf, Cmd c, Cmd mc)
{
	extern int scrolling;
	static int lastud = 0;
	int cnt;

	(void)buf; @+(void)mc;
	scrolling = 1;
	switch (c.chr) {
	case CTRL('E'):
		cnt = +c.count;
		@+break;
	case CTRL('Y'):
		cnt = -c.count;
		@+break;
	case CTRL('U'):
	case CTRL('D'):
		if (c.count) lastud = c.count;
		cnt = curwin->nl / 3;
		if (lastud) cnt = lastud;
		if (c.chr == CTRL('U')) cnt = -cnt;
		break;
	}
	win_scroll(curwin, cnt);
	return 0;
}

@ The tag window is a specific to this implementation, \.{\^T}
toggles the tag window.  This is a scratch area used to input
complex commands acting on the underlying main window.  This
concept is taken from Pike's Acme text editor and adapted to a
keyboard driven editor with minimal visual footprint.
@^Acme like feature@>

@<Subr...@>=
static int a_tag(char buf, Cmd c, Cmd mc)
{
	(void)buf; @+(void)c; @+(void)mc;
	return chwin(win_tag_toggle(curwin)), 0;
}

@ Switching between windows is done by clicks.  One can also use
the keyboard command \.{\^L} followed by any of the basic line
motions \.h, \.j, \.k, and \.l to jump directly to a neighbor
window.

@<Subr...@>=
static int a_swtch(char buf, Cmd c, Cmd mc)
{
	(void)buf; @+(void)mc;
	switch (c.arg) {
	default:
		return 1;
	case 'h':
	case 'j':
	case 'k':
	case 'l':
		return chwin(win_edge(curwin, c.arg)), 0;
	}
}

@ Still from Acme, the editor allows the user to run arbitrary
commands in a buffer.  The |ex_run| function is defined in an
external module since it is not tied to the editing logic.
@^Acme like feature@>

@<Subr...@>=
static int a_run(char buf, Cmd c, Cmd mc)
{
	(void)buf; @+(void)c; @+(void)mc;
	return ex_run(curwin, curwin->cu);
}

@ The insertion commands are all treated in the following procedure.
The only tricky case in this code is the handling of the \.O command. We
first split the current line at the end of the indentation then rely
on the code in |@<Insert a new line...@>| to restore it, effectively
creating a new line above the current one.  The cursor is then placed
after the indentation on the freshly created line.  This code works even
when there is a count because the initial |insert('\n')| is correctly
repeated by the insertion code.

@<Subr...@>=
static int a_ins(char buf, Cmd c, Cmd mc)
{
	unsigned cu;

	(void)buf; @+(void)mc;
	if (c.chr == 'a' && curwin->cu != buf_eol(curb, curwin->cu))
		curwin->cu++;
	if (c.chr == 'A' || c.chr == 'o')
		curwin->cu = buf_eol(curb, curwin->cu);
	if (c.chr == 'I' || c.chr == 'O')
		cu = curwin->cu = blkspn(buf_bol(curb, curwin->cu));
	@<Switch to insertion mode@>;
	cnti = c.count; // repeat according to the command count
	if (c.chr == 'o') insert('\n');
	if (c.chr == 'O') insert('\n'), curwin->cu = cu;
	return 0;
}

@ Most commands have their action defined by the |keys| array, so
we simply need to call this action.  The repeat and the undo commands
are treated explicitely here because they need more context than
regular commands.  To implement these two commands, each successfully
executed action together with the {\sl undo direction} are remembered
in static variables.

@d risctrl(r) (r < 0x1b)

@<Subr...@>=
static void docmd(char buf, Cmd c, Cmd m)
{
	static char lastbuf;
	static Cmd lastc, lastm;
	static int redo;

	if (keys[c.chr].flags & CIsMotion) {
		Motion m = {curwin->cu, 0, 0};
		if (keys[c.chr].motion(0, c, &m) == 0)
			curwin->cu = m.end;
		return;
	}

	@<Handle the repeat command@>;
	@<Handle the undo command@>;

	if (keys[c.chr].cmd != 0) {
		if (keys[c.chr].cmd(buf, c, m) || risctrl(c.chr))
			return;
		lastbuf = buf, lastc = c, lastm = m;
	}
}

@ The mechanism used to implement infinite undo is the same as in
Keith Bostic's \.{vi}. It makes the \.u command behave like in the
historic implementation.  The standard behavior for this command
is to alternate between two states before and after the last change.
To access more of the undo history the user has to use \.u
once and then repeat the undo command using the \.. command.
Similarly, to redo changes, \.u is used once to commute the undo
direction and then chained with a sequence of \.. commands.  The
|redo| variable stores the current undo direction, if it is 1 the
editor is redoing, if it is 0 the editor is undoing.

@ This implementation of the repeat command is very close to the
\.{POSIX} specification.  The special case for the \.u command is
explained above.  We also need to make sure that |lastf| is locked
because the undo command does not override the last character
searched by the \.t and \.f family of commands.  The specification
also mandates that if a count is specified it overwrites both the
count of the edition and the one of the motion commands repeated.

@<Handle the repeat command@>=
if (c.chr == '.') {
	Cmd cpyc = lastc, cpym = lastm;

	if (lastc.chr == 0) return;
	assert(lastc.chr != '.');

	if (lastc.chr == 'u')
		redo = !redo;
	else
		assert(redo == 0);

	if (c.count) {
		lastm.count = 1;
		lastc.count = c.count;
	}

	lastf.locked = lasti.locked = 1;
	docmd(lastbuf, lastc, lastm);
	if (mode == Insert)
		@<Insert runes stored in the |lasti| buffer@>;
	lastf.locked = lasti.locked = 0;

	lastc = cpyc, lastm = cpym;
	return;
}

@ If the last executed command is \.o or \.O one newline has already
been inserted by the command itself so we start inserting saved runes
only from position 1.

@<Insert runes stored...@>=
{	unsigned p = 0;

	if (lastc.chr == 'o' || lastc.chr == 'O')
		p = 1;
	while (p < lasti.len)
		insert(lasti.buf[p++]);
	insert(GKEsc);
}

@ The undo command is trivially implemented using the function provided
by the buffer module.  To implement the alternating behavior, |redo| is
commuted at each invocation.

@<Handle the undo command@>=
if (c.chr == 'u') {
	redo = !redo;
	eb_undo(curwin->eb, redo, &curwin->cu);
	lastc = c;
	return;
} else
	redo = 0; // for any other command, reset the |redo| flag


@* Key array definition.  This is the boring list of all commands
implemented above.  It also contains different flags used during
the parsing.

@ @<Local types@>=
typedef int @[@] motion_t(int, Cmd, Motion *);
typedef int @[@] cmd_t(char, Cmd, Cmd);

@ We need to predeclare all actions in order to use them in the |keys|
array below.

@<Predecl...@>=
static cmd_t a_d, a_c, a_y, a_pP, a_m, a_ins, a_run, a_scroll, a_swtch, a_tag, a_write, a_exit;

@ @<Other key fields@>=
union {
	motion_t *motion;
	cmd_t *cmd;
};

@ @d Mtn(flags, f) {@+CIsMotion|flags, .motion = f}
@d Act(flags, f) {@+flags, .cmd = f}
@<Key def...@>=
['h'] = Mtn(0, m_hl), ['l'] = Mtn(0, m_hl),@/
['j'] = Mtn(0,m_jk), ['k'] = Mtn(0, m_jk),@/
['t'] = Mtn(CHasArg, m_find), ['f'] = Mtn(CHasArg, m_find),@/
['T'] = Mtn(CHasArg, m_find), ['F'] = Mtn(CHasArg, m_find),@/
[','] = Mtn(0, m_repf), [';'] = Mtn(0, m_repf),@/
['0'] = Mtn(0, m_bol), ['^'] = Mtn(0, m_bol),@/
['$'] = Mtn(0, m_eol), ['_'] = Mtn(0, m_line),@/
['w'] = Mtn(0, m_ewEW), ['W'] = Mtn(0, m_ewEW),@/
['e'] = Mtn(0, m_ewEW), ['E'] = Mtn(0, m_ewEW),@/
['b'] = Mtn(0, m_bB), ['B'] = Mtn(0, m_bB),@/
['{'] = Mtn(0, m_par), ['}'] = Mtn(0, m_par),@/
['%'] = Mtn(0, m_match), ['G'] = Mtn(CZeroCount, m_G),@/
['H'] = Mtn(0, m_HML), ['L'] = Mtn(0, m_HML),@/
['M'] = Mtn(0, m_HML),@/
['n'] = Mtn(0, m_nN), ['N'] = Mtn(0, m_nN),@/
['/'] = Mtn(0, m_sel),@/
['\''] = Mtn(CHasArg, m_mark), ['`'] = Mtn(CHasArg, m_mark),@/
['d'] = Act(CHasMotion, a_d), ['x'] = Act(0, a_d),@/
['c'] = Act(CHasMotion, a_c), ['y'] = Act(CHasMotion, a_y),@/
['i'] = Act(0, a_ins), ['I'] = Act(0, a_ins),@/
['a'] = Act(0, a_ins), ['A'] = Act(0, a_ins),@/
['o'] = Act(0, a_ins), ['O'] = Act(0, a_ins),@/
['p'] = Act(0, a_pP), ['P'] = Act(0, a_pP),@/
['.'] = Act(CZeroCount, 0), ['m'] = Act(CHasArg, a_m),@/
[CTRL('D')] = Act(CZeroCount, a_scroll),@/
[CTRL('U')] = Act(CZeroCount, a_scroll),@/
[CTRL('E')] = Act(0, a_scroll), [CTRL('Y')] = Act(0, a_scroll),@/
[CTRL('T')] = Act(0, a_tag), [CTRL('I')] = Act(0, a_run),@/
[CTRL('L')] = Act(CHasArg, a_swtch),@/
[CTRL('W')] = Act(0, a_write), [CTRL('Q')] = Act(0, a_exit),

@** Index.
