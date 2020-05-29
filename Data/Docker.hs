{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase        #-}

-- | A Simple DSL for describing and generating Dockerfiles in Haskell
--
-- Compatible w/ Docker v18.03
--
-- @
-- main :: IO ()
-- main = putStrLn $
--   dockerfile $ do
--       from "debian:stable"
--       maintainer "creichert <creichert07@gmail.com>"
--       run "apt-get -y update"
--       run "apt-get -y upgrade"
--       cmd [ "echo", "hello world"]
-- @


module Data.Docker
       (
         -- * Types
         Docker
       , CopyOpt(..)
       , dockerfile
       , dockerfileWrite
       , Script
       , ScriptFile
       , As
       , Param
         -- * Docker Instructions
       , comment
       , from
       , fromas
       , run
       , cmd
       , label
       , maintainer
       , expose
       , env
       , add
       , addchown
       , copy
       , copyfrom
       , copychown
       , entrypoint
       , volume
       , user
       , workdir
       , arg
       , onbuild
       , stopsignal
       , healthcheck
--       , shell
       ) where

import Control.Monad.Writer


-- | A 'Dockerfile' is represented as a list of instructions.
type DockerFile = [Instruction]

-- | A 'Docker' writer monad for creating 'Dockerfile's
type Docker a = Writer DockerFile a

-- | Render a list of 'Docker' instructions to a 'String'.
dockerfile :: Docker a -> String
dockerfile = unlines . map prettyCmd . execWriter

-- | Render a list of 'Docker' instructions to a 'FilePath'.
dockerfileWrite :: FilePath -> Docker a -> IO ()
dockerfileWrite fp docker = do
    let content = "# this file was generated by the `dockerfile` haskell library"
                : ""
                : fmap prettyCmd (execWriter docker)
    writeFile fp (unlines content)

type Script     = String
type ScriptFile = FilePath
type Param      = String
type ImageName  = String
type As         = String


-- | Dockerfile instruction set
--
-- This data type is not exposed. All Docker commands/instructions are
-- exposed through combinator functions intended to be run from w/in
-- `dockerfile` and similar functions.
data Instruction
  = Comment String
  | From ImageName (Maybe As)
  | Run Script  -- File [ScriptParam]
  | Cmd [ ScriptFile ]
  | Label [(String, String)]
  | Maintainer String
  | Expose Int
  | Env String String
  | Add [FilePath] FilePath [AddOpt]
  | Copy [FilePath] FilePath [CopyOpt]
  | Entrypoint String [Param]
  | Volume [FilePath]
  | User String
  | WorkDir FilePath
  | Arg String (Maybe String)
  | OnBuild Instruction
  | StopSignal String
  | HealthCheck (Maybe ([String], String))
  | Shell
  deriving Show

prettyCmd :: Instruction -> String
prettyCmd = \case
    Comment s                      -> "# " ++ s
    From f mas                     -> "FROM " ++ f ++ maybe "" (" AS " ++) mas
    Run scr                        -> "RUN " ++ scr
    Cmd cmds                       -> "CMD " ++ show cmds
    Label kvs                      -> "LABEL " ++ unwords (fmap (\(k,v) -> show k ++ "=" ++ show v) kvs)
    Maintainer m                   -> "MAINTAINER " ++ m
    Expose p                       -> "EXPOSE " ++ show p
    Env k v                        -> "ENV " ++ k ++ " " ++ v
    Add s d opts                   -> "ADD " ++ (if null opts then "" else renderOpts opts ++ " ")
                                             ++ unwords s
                                             ++ " "
                                             ++ d
    Copy s d opts                  -> "COPY " ++ (if null opts then "" else renderOpts opts ++ " ")
                                              ++ unwords s
                                              ++ " "
                                              ++ d
    Entrypoint e ps                -> "ENTRYPOINT " ++ show (e:ps)
    Volume vs                      -> "VOLUME " ++ show vs
    User u                         -> "USER " ++ u
    WorkDir cwd                    -> "WORKDIR " ++ cwd
    Arg name mval                  -> "ARG " ++ name ++ maybe "" ("=" ++) mval
    OnBuild _instr                 -> error "ONBUILD instruction is not currently supported."
    StopSignal sig                 -> "STOPSIGNAL " ++ sig
    HealthCheck (Just (opts, c))   -> "HEALTHCHECK " ++ unwords opts ++ " CMD " ++ c
    HealthCheck Nothing            -> "HEALTHCHECK NONE"
    Shell                          -> error "SHELL instruction is not currently supported"

class DockerOpt a where
    renderDockerOpt :: a -> String

data CopyOpt = CopyOptFrom String
             | CopyOptChown [String]
             deriving Show

instance DockerOpt CopyOpt where
    renderDockerOpt = \case
        CopyOptFrom n       -> "--from=" ++ n
        CopyOptChown chowns -> unwords (fmap ("--chown=" ++) chowns)

data AddOpt = AddOptFrom String
            | AddOptChown [String]
            deriving Show

instance DockerOpt AddOpt where
    renderDockerOpt = \case
        AddOptFrom n       -> "--from=" ++ n
        AddOptChown chowns -> unwords (fmap ("--chown=" ++) chowns)

renderOpts :: DockerOpt a => [a] -> String
renderOpts = unwords . fmap renderDockerOpt

-- * Instructions

-- | Add a comment to the Dockerfile. @"# "@ is automatically prepended
-- to the comment.
comment :: String -> Docker ()
comment s = tell [ Comment s ]

-- | The @FROM@ instruction initializes a new build stage and sets
-- the Base Image for subsequent instructions. As such, a valid
-- Dockerfile must start with a @FROM@ instruction. The image can be
-- any valid image – it is especially easy to start by pulling an
-- image from the Public Repositories.
--
-- @ARG@ is the only instruction that may precede @FROM@ in the
-- Dockerfile. See Understand how @ARG@ and @FROM@ interact.
--
-- @FROM@ can appear multiple times within a single Dockerfile to
-- create multiple images or use one build stage as a dependency for
-- another. Simply make a note of the last image ID output by the
-- commit before each new FROM instruction. Each @FROM@ instruction
-- clears any state created by previous instructions.
--
-- Optionally a name can be given to a new build stage by adding @AS
-- name@ to the @FROM@ instruction. The name can be used in
-- subsequent @FROM@ and @COPY --from=<name|index>@ instructions to
-- refer to the image built in this stage.
--
-- The @tag@ or @digest@ values are optional. If you omit either of
-- them, the builder assumes a @latest@ tag by default. The builder
-- returns an error if it cannot find the tag value.
from :: String -> Docker ()
from f = tell [ From f Nothing ]

fromas :: String -> As -> Docker ()
fromas f as = tell [ From f (Just as) ]

-- | RUN has 2 forms:
--
-- - RUN <command> (shell form, the command is run in a shell, which
--   by default is /bin/sh -c on Linux or cmd /S /C on Windows)
--
-- - RUN ["executable", "param1", "param2"] (exec form)
--
-- The RUN instruction will execute any commands in a new layer on
-- top of the current image and commit the results. The resulting
-- committed image will be used for the next step in the Dockerfile.
--
-- Layering RUN instructions and generating commits conforms to the
-- core concepts of Docker where commits are cheap and containers can
-- be created from any point in an image’s history, much like source
-- control.
--
-- The exec form makes it possible to avoid shell string munging, and
-- to RUN commands using a base image that does not contain the
-- specified shell executable.
--
-- The default shell for the shell form can be changed using the
-- SHELL command.
run :: Script -> Docker ()
run scr = tell [ Run scr ]

-- | The CMD instruction has three forms:
--
-- Syntax:
--
-- @
-- CMD ["executable","param1","param2"] (exec form, this is the preferred form)
-- CMD ["param1","param2"] (as default parameters to ENTRYPOINT)
-- CMD command param1 param2 (shell form)
-- @
--
-- There can only be one CMD instruction in a Dockerfile. If you list
-- more than one CMD then only the last CMD will take effect.
-- @
--
-- If the CMD instruction does not specify an executable, an
-- ENTRYPOINT instruction must be present.
cmd :: [ScriptFile] -> Docker ()
cmd cs = tell [ Cmd cs ]

-- | The LABEL instruction adds metadata to an image. A LABEL is a
-- key-value pair. To include spaces within a LABEL value, use quotes and
-- blackslashes as you would in command-line parsing.
--
-- Syntax:
--
-- @
-- LABEL com.example.label-without-value
-- LABEL com.example.label-with-value="foo"
-- LABEL version="1.0"
-- LABEL description="This text illustrates \
-- that label-values can span multiple lines."
-- @
label :: [(String, String)] -> Docker ()
label kvs = tell [ Label kvs ]

-- | The MAINTAINER instruction sets the Author field of the
-- generated images. The LABEL instruction is a much more flexible
-- version of this and you should use it instead, as it enables
-- setting any metadata you require, and can be viewed easily, for
-- example with docker inspect. To set a label corresponding to the
-- MAINTAINER field you could use:
--
--     LABEL maintainer="SvenDowideit@home.org.au"
--
-- This will then be visible from docker inspect with the other
-- labels.
maintainer :: String -> Docker ()
maintainer m = tell [ Maintainer m ]

-- | EXPOSE <port> [<port>...]
expose :: Int -> Docker ()
expose p = tell [ Expose p ]

-- |
--
--   The ENV instruction sets the environment variable <key> to the
-- value <value>. This value will be in the environment of all
-- "descendent" Dockerfile commands and can be replaced inline in many as
-- well.
--
--
--  Syntax:
--
-- @
-- ENV <key> <value>
-- ENV <key>=<value> ...
-- @
--
-- The second form allows multiple key value pairs to be specified
--
-- @
--  ENV myName="John Doe" myDog=Rex\ The\ Dog \
--      myCat=fluffy
--  and
--
--  ENV myName John Doe
--  ENV myDog Rex The Dog
--  ENV myCat fluffy
-- @
env :: String -> String -> Docker ()
env k v = tell [ Env k v ]

-- | ADD has two forms:
--
-- - @ADD [--chown=<user>:<group>] <src>... <dest>@
--
-- - @ADD [--chown=<user>:<group>] ["<src>",... "<dest>"]@ (this form
--   is required for paths containing whitespace)
--
-- > Note: The @--chown@ feature is only supported on Dockerfiles
-- > used to build Linux containers, and will not work on Windows
-- > containers. Since user and group ownership concepts do not
-- > translate between Linux and Windows, the use of @/etc/passwd@
-- > and @/etc/group@ for translating user and group names to IDs
-- > restricts this feature to only be viable for Linux OS-based
-- > containers.
--
-- The ADD instruction copies new files, directories or remote file
-- URLs from <src> and adds them to the filesystem of the image at
-- the path <dest>.
--
-- Multiple <src> resources may be specified but if they are files or
-- directories, their paths are interpreted as relative to the source
-- of the context of the build.
--
-- ADD obeys the following rules:
--
-- - The <src> path must be inside the context of the build; you
--   cannot ADD ../something /something, because the first step of a
--   docker build is to send the context directory (and
--   subdirectories) to the docker daemon.
--
-- - If <src> is a URL and <dest> does not end with a trailing slash,
--   then a file is downloaded from the URL and copied to <dest>.
--
-- - If <src> is a URL and <dest> does end with a trailing slash,
--   then the filename is inferred from the URL and the file is
--   downloaded to <dest>/<filename>. For instance, ADD
--   http://example.com/foobar / would create the file /foobar. The
--   URL must have a nontrivial path so that an appropriate filename
--   can be discovered in this case (http://example.com will not
--   work).
--
-- - If <src> is a directory, the entire contents of the directory
--   are copied, including filesystem metadata.
--
-- - Note: The directory itself is not copied, just its contents.
--
-- - If <src> is a local tar archive in a recognized compression
--   format (identity, gzip, bzip2 or xz) then it is unpacked as a
--   directory. Resources from remote URLs are not decompressed. When
--   a directory is copied or unpacked, it has the same behavior as
--   tar -x, the result is the union of:
--
-- - Whatever existed at the destination path and The contents of the
--   source tree, with conflicts resolved in favor of “2.” on a
--   file-by-file basis.  Note: Whether a file is identified as a
--   recognized compression format or not is done solely based on the
--   contents of the file, not the name of the file. For example, if
--   an empty file happens to end with .tar.gz this will not be
--   recognized as a compressed file and will not generate any kind
--   of decompression error message, rather the file will simply be
--   copied to the destination.
--
-- - If <src> is any other kind of file, it is copied individually
--   along with its metadata. In this case, if <dest> ends with a
--   trailing slash /, it will be considered a directory and the
--   contents of <src> will be written at <dest>/base(<src>).
--
-- - If multiple <src> resources are specified, either directly or
--   due to the use of a wildcard, then <dest> must be a directory,
--   and it must end with a slash /.
--
-- - If <dest> does not end with a trailing slash, it will be
--   considered a regular file and the contents of <src> will be
--   written at <dest>.
--
-- - If <dest> doesn’t exist, it is created along with all missing
--   directories in its path.
add :: [FilePath] -> FilePath -> Docker ()
add k v = tell [ Add k v [] ]

addchown :: [String] -> [FilePath] -> FilePath -> Docker ()
addchown chowns k v = tell [ Add k v [AddOptChown chowns] ]

-- |
-- COPY has two forms:
--
-- COPY <src>... <dest>
-- COPY ["<src>"... "<dest>"] (this form is required for paths containing whitespace)
--
-- The COPY instruction copies new files or directories from <src>
-- and adds them to the filesystem of the container at the path <dest>.
copy :: [FilePath] -> FilePath -> Docker ()
copy s d = tell [ Copy s d [] ]

copyfrom :: String -> [FilePath] -> FilePath -> Docker ()
copyfrom frm s d = tell [ Copy s d [CopyOptFrom frm] ]

copychown :: [String] -> [FilePath] -> FilePath -> Docker ()
copychown chowns s d = tell [ Copy s d [CopyOptChown chowns] ]

-- | An ENTRYPOINT allows you to configure a container that will run as
-- an executable.
--
-- @
-- ENTRYPOINT ["executable", "param1", "param2"] (the preferred exec form)
-- ENTRYPOINT command param1 param2 (shell form)
-- @
entrypoint :: FilePath -> [Param] -> Docker ()
entrypoint e ps = tell [ Entrypoint e ps ]

-- | @ VOLUME ["/data"] @
--
-- The VOLUME instruction creates a mount point with the specified
-- name and marks it as holding externally mounted volumes from native
-- host or other containers.
volume :: [FilePath] -> Docker ()
volume vs  = tell [ Volume vs ]

-- | USER daemon
--
-- The USER instruction sets the user name or UID to use when running the
-- image and for any RUN, CMD and ENTRYPOINT instructions that follow it
-- in the Dockerfile.
user :: String -> Docker ()
user u = tell [ User u ]

-- | The WORKDIR instruction sets the working directory for any RUN, CMD,
-- ENTRYPOINT, COPY and ADD instructions that follow it in the
-- Dockerfile.
--
-- @ WORKDIR /path/to/workdir @
workdir :: FilePath -> Docker ()
workdir cwd = tell [ WorkDir cwd ]

-- | The ARG instruction defines a variable that users can pass at
-- build-time to the builder with the docker build command using the
-- @--build-arg <varname>=<value> flag@. If a user specifies a build
-- argument that was not defined in the Dockerfile, the build outputs
-- a warning.
--
-- = Default values
--
-- An ARG instruction can optionally include a default value:
--
-- @
-- FROM busybox
-- ARG user1=someuser
-- ARG buildno=1
-- @
--
-- If an ARG instruction has a default value and if there is no value
-- passed at build-time, the builder uses the default.
arg :: String -> Maybe String -> Docker ()
arg name val = tell [ Arg name val ]

-- | The ONBUILD instruction adds to the image a trigger
-- instruction to be executed at a later time, when the image is used as
-- the base for another build. The trigger will be executed in the
-- context of the downstream build, as if it had been inserted
-- immediately after the FROM instruction in the downstream Dockerfile.
--
-- @
-- [...]
-- ONBUILD ADD . /app/src
-- ONBUILD RUN /usr/local/bin/python-build --dir /app/src
-- [...]
-- @
onbuild :: Instruction -> Docker ()
onbuild _ = error "ONBUILD instruction is not yet supported"

-- | The STOPSIGNAL instruction sets the system call signal that will
-- be sent to the container to exit. This signal can be a valid
-- unsigned number that matches a position in the kernel’s syscall
-- table, for instance 9, or a signal name in the format SIGNAME, for
-- instance SIGKILL.
stopsignal :: String -> Docker ()
stopsignal c = tell [StopSignal c]

-- | The HEALTHCHECK instruction has two forms:
--
-- - HEALTHCHECK [OPTIONS] CMD command (check container health by
-- - running a command inside the container)
--
-- - HEALTHCHECK NONE (disable any healthcheck inherited from the
-- - base image)
--
-- The HEALTHCHECK instruction tells Docker how to test a container
-- to check that it is still working. This can detect cases such as a
-- web server that is stuck in an infinite loop and unable to handle
-- new connections, even though the server process is still running.
--
-- When a container has a healthcheck specified, it has a health
-- status in addition to its normal status. This status is initially
-- starting. Whenever a health check passes, it becomes healthy
-- (whatever state it was previously in). After a certain number of
-- consecutive failures, it becomes unhealthy.
--
-- The options that can appear before CMD are:
--
-- @
-- --interval=DURATION (default: 30s)
-- --timeout=DURATION (default: 30s)
-- --start-period=DURATION (default: 0s)
-- --retries=N (default: 3)
-- @
--
-- The health check will first run interval seconds after the
-- container is started, and then again interval seconds after each
-- previous check completes.
--
-- If a single run of the check takes longer than timeout seconds
-- then the check is considered to have failed.
--
-- It takes retries consecutive failures of the health check for the
-- container to be considered unhealthy.
--
-- Start period provides initialization time for containers that need
-- time to bootstrap. Probe failure during that period will not be
-- counted towards the maximum number of retries. However, if a
-- health check succeeds during the start period, the container is
-- considered started and all consecutive failures will be counted
-- towards the maximum number of retries.
--
-- There can only be one HEALTHCHECK instruction in a Dockerfile. If
-- you list more than one then only the last HEALTHCHECK will take
-- effect.
--
-- The command after the CMD keyword can be either a shell command
-- (e.g. HEALTHCHECK CMD /bin/check-running) or an exec array (as
-- with other Dockerfile commands; see e.g. ENTRYPOINT for details).
--
-- The command’s exit status indicates the health status of the
-- container. The possible values are:
--
-- - 0: success - the container is healthy and ready for use
--
-- - 1: unhealthy - the container is not working correctly
--
-- - 2: reserved - do not use this exit code
--
-- - For example, to check every five minutes or so that a web-server
-- - is able to serve the site’s main page within three seconds:
--
-- HEALTHCHECK --interval=5m --timeout=3s \
--   CMD curl -f http://localhost/ || exit 1
--
-- To help debug failing probes, any output text (UTF-8 encoded) that
-- the command writes on stdout or stderr will be stored in the
-- health status and can be queried with docker inspect. Such output
-- should be kept short (only the first 4096 bytes are stored
-- currently).
--
-- When the health status of a container changes, a health_status
-- event is generated with the new status.
--
-- The HEALTHCHECK feature was added in Docker 1.12.

healthcheck :: Maybe ([String], String) -> Docker ()
healthcheck = \case
    Just (opts, cmd') -> tell [HealthCheck (Just (opts, cmd'))]
    Nothing           -> tell [HealthCheck Nothing]

shell :: String -> Docker ()
shell = error "SHELL instruction is not yet supported"
