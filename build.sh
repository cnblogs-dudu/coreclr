#!/usr/bin/env bash

usage()
{
    echo "Usage: $0 [BuildArch] [BuildType] [clean] [verbose] [clangx.y]"
    echo "BuildArch can be: x64"
    echo "BuildType can be: Debug, Release"
    echo "clean - optional argument to force a clean build."
    echo "verbose - optional argument to enable verbose build output."
    echo "clangx.y - optional argument to build using clang version x.y."

    exit 1
}

setup_dirs()
{
    echo Setting up directories for build
    
    mkdir -p "$__RootBinDir"
    mkdir -p "$__BinDir"
    mkdir -p "$__LogsDir"
    mkdir -p "$__IntermediatesDir"
}

# Performs "clean build" type actions (deleting and remaking directories)

clean()
{
    echo Cleaning previous output for the selected configuration
    rm -rf "$__BinDir"
    rm -rf "$__IntermediatesDir"
	
    rm -rf "$__TestWorkingDir"
    rm -rf "$__TestIntermediatesDir"
	
    rm -rf "$__LogsDir/*_$__BuildOS__$__BuildArch__$__BuildType.*"
}

# Check the system to ensure the right pre-reqs are in place

check_prereqs()
{
    echo "Checking pre-requisites..."
    
    # Check presence of CMake on the path
    hash cmake 2>/dev/null || { echo >&2 "Please install cmake before running this script"; exit 1; }
    
    # Check for clang
    hash clang-$__ClangMajorVersion.$__ClangMinorVersion 2>/dev/null ||  hash clang$__ClangMajorVersion$__ClangMinorVersion 2>/dev/null ||  hash clang 2>/dev/null || { echo >&2 "Please install clang before running this script"; exit 1; }
   
}

check_nuget()
{
    # Copy from build.sh in corefx 
    # Pull NuGet.exe down if we don't have it already    
    if [ ! -e "$__NugetPath" ]; then
        which curl wget > /dev/null 2> /dev/null
        if [ $? -ne 0 -a $? -ne 1 ]; then
            echo "cURL or wget is required to build corefx. Please see https://github.com/dotnet/corefx/wiki/Building-On-Unix for more details."
            exit 1
        fi
        echo "Restoring NuGet.exe..."
    
        which wget > /dev/null 2> /dev/null
        if [ $? -ne 0 ]; then
           curl -sSL --create-dirs -o $__NugetPath https://api.nuget.org/downloads/nuget.exe
        else
           mkdir -p $__PackagesDir
           wget -q -O $__NugetPath https://api.nuget.org/downloads/nuget.exe
        fi
    
        if [ $? -ne 0 ]; then
            echo "Failed to restore NuGet.exe."
            exit 1
        fi
    fi
}

check_msbuild()
{
    __MsbuildPackageId="Microsoft.Build.Mono.Debug"
    __MsbuildPackageVersion="14.1.0.0-prerelease"
    __MsbuildPath=$__PackagesDir/$__MsbuildPackageId.$__MsbuildPackageVersion/lib/MSBuild.exe    
    # Grab the MSBuild package if we don't have it already
    if [ ! -e "$__MsbuildPath" ]; then
        echo "Restoring MSBuild..."
        mono "$__NugetPath" install $__MsbuildPackageId -Version $__MsbuildPackageVersion -ConfigFile "$__NugetConfig" -OutputDirectory "$__PackagesDir"
        if [ $? -ne 0 ]; then
            echo "Failed to restore MSBuild."
            exit 1
        fi
    fi
}

build_mscorlib()
{
    echo "Commencing mscorlib build"
    check_msbuild
    __MScorlibBuildLog=$__LogsDir/mscorlib_$__BuildOS"_"$__BuildArch"_"$__BuildType.log
    mono $__MsbuildPath "$__ProjectDir\build.proj" /nologo /verbosity:minimal "/fileloggerparameters:Verbosity=diag;LogFile=$__MScorlibBuildLog" /p:OS=$__BuildOS "$@"
    if [ $? != 0 ]; then
        echo "Failed to build mscorlib."
        exit 1
    fi
    echo "Build mscorlib successfully."
}

build_coreclr()
{
    # All set to commence the build
    
    echo "Commencing build of native components for $__BuildOS.$__BuildArch.$__BuildType"
    cd "$__IntermediatesDir"
    
    # Regenerate the CMake solution
    echo "Invoking cmake with arguments: \"$__ProjectRoot\" $__CMakeArgs"
    "$__ProjectRoot/src/pal/tools/gen-buildsys-clang.sh" "$__ProjectRoot" $__ClangMajorVersion $__ClangMinorVersion $__CMakeArgs
    
    # Check that the makefiles were created.
    
    if [ ! -f "$__IntermediatesDir/Makefile" ]; then
        echo "Failed to generate native component build project!"
        exit 1
    fi

    # Get the number of processors available to the scheduler
    # Other techniques such as `nproc` only get the number of
    # processors available to a single process.
    if [ `uname` = "FreeBSD" ]; then
	NumProc=`sysctl hw.ncpu | awk '{ print $2+1 }'`
    else
	NumProc=$(($(getconf _NPROCESSORS_ONLN)+1))
    fi
    
    # Build CoreCLR
    
    echo "Executing make install -j $NumProc $__UnprocessedBuildArgs"

    make install -j $NumProc $__UnprocessedBuildArgs
    if [ $? != 0 ]; then
        echo "Failed to build coreclr components."
        exit 1
    fi
}

echo "Commencing CoreCLR Repo build"

# Argument types supported by this script:
#
# Build architecture - valid value is: x64.
# Build Type         - valid values are: Debug, Release
#
# Set the default arguments for build

# Obtain the location of the bash script to figure out whether the root of the repo is.
__ProjectRoot="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
__BuildArch=x64
# Use uname to determine what the OS is.
OSName=$(uname -s)
case $OSName in
    Linux)
        __BuildOS=Linux
        ;;

    Darwin)
        __BuildOS=OSX
        ;;

    FreeBSD)
        __BuildOS=FreeBSD
        ;;

    OpenBSD)
        __BuildOS=OpenBSD
        ;;

    NetBSD)
        __BuildOS=NetBSD
        ;;

    *)
        echo "Unsupported OS $OSName detected, configuring as if for Linux"
        __BuildOS=Linux
        ;;
esac
__MSBuildBuildArch=x64
__BuildType=Debug
__CMakeArgs=DEBUG

# Set the various build properties here so that CMake and MSBuild can pick them up
__ProjectDir="$__ProjectRoot"
__SourceDir="$__ProjectDir/src"
__PackagesDir="$__ProjectDir/packages"
__NugetPath="$__PackagesDir/NuGet.exe"
__NugetConfig="$__ProjectDir/NuGet.Config"
__RootBinDir="$__ProjectDir/bin"
__LogsDir="$__RootBinDir/Logs"
__UnprocessedBuildArgs=
__MSBCleanBuildArgs=
__CleanBuild=false
__VerboseBuild=false
__ClangMajorVersion=3
__ClangMinorVersion=5
__MscorlibOnly=0

for i in "$@"
    do
        lowerI="$(echo $i | awk '{print tolower($0)}')"
        case $lowerI in
        -?|-h|--help)
        usage
        exit 1
        ;;
        x64)
        __BuildArch=x64
        __MSBuildBuildArch=x64
        ;;
        debug)
        __BuildType=Debug
        ;;
        release)
        __BuildType=Release
        __CMakeArgs=RELEASE
        ;;
        clean)
        __CleanBuild=1
        ;;
        verbose)
        __VerboseBuild=1
        ;;
        clang3.5)
        __ClangMajorVersion=3
        __ClangMinorVersion=5
        ;;
        clang3.6)
        __ClangMajorVersion=3
        __ClangMinorVersion=6
        ;;
        clang3.7)
        __ClangMajorVersion=3
        __ClangMinorVersion=7
        ;;
        mscorlib)
        __MscorlibOnly=1
        ;;
        *)
        __UnprocessedBuildArgs="$__UnprocessedBuildArgs $i"
    esac
done

# Set the remaining variables based upon the determined build configuration
__BinDir="$__RootBinDir/Product/$__BuildOS.$__BuildArch.$__BuildType"
__PackagesBinDir="$__BinDir/.nuget"
__ToolsDir="$__RootBinDir/tools"
__TestWorkingDir="$__RootBinDir/tests/$__BuildOS.$__BuildArch.$__BuildType"
__IntermediatesDir="$__RootBinDir/obj/$__BuildOS.$__BuildArch.$__BuildType"
__TestIntermediatesDir="$__RootBinDir/tests/obj/$__BuildOS.$__BuildArch.$__BuildType"

# Specify path to be set for CMAKE_INSTALL_PREFIX.
# This is where all built CoreClr libraries will copied to.
export __CMakeBinDir="$__BinDir"

# Build mscorlib
if [ $__MscorlibOnly == 1 ]; then
check_nuget
build_mscorlib
exit 0
fi

# Configure environment if we are doing a clean build.
if [ $__CleanBuild == 1 ]; then
    clean
fi

# Configure environment if we are doing a verbose build
if [ $__VerboseBuild == 1 ]; then
	export VERBOSE=1
fi

# Make the directories necessary for build if they don't exist

setup_dirs

# Check prereqs.

check_prereqs

# Build the coreclr (native) components.

build_coreclr

# Build complete

echo "Repo successfully built."
echo "Product binaries are available at $__BinDir"
exit 0
