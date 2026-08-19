#include "pch.hpp"

#include "cstdmf/md5.hpp"
#include "cstdmf/slow_task.hpp"

#include "resmgr/bwresource.hpp"
#include "resmgr/multi_file_system.hpp"
#include "resmgr/zip_file_system.hpp"
#include "resmgr/zip_section.hpp"

#include "effect_compiler.hpp"
#include "managed_effect.hpp"
#include "effect_helpers.hpp"

#include <cstdio>

BW_BEGIN_NAMESPACE

namespace {
	// Simple debug log for early init diagnostics
	void fxDebugLog( const char* fmt, ... )
	{
		FILE* f = fopen( "bwclient_fx_debug.log", "a" );
		if (f)
		{
			va_list args;
			va_start( args, fmt );
			vfprintf( f, fmt, args );
			va_end( args );
			fclose( f );
		}
	}

	// This avoids spam in the debug window for loading/unloading
	// the D3D compiler DLL whenever a shader gets rebuilt. Just
	// load once on startup and leave it loaded.
	class CompilerModuleHolder
	{
	public:
		CompilerModuleHolder()
		{
			hModule_ = LoadLibrary( TEXT( "D3DCompiler_42.dll" ) );
		}

		~CompilerModuleHolder()
		{
			if (hModule_)
			{
				FreeLibrary( hModule_ );
			}
		}

	private:
		HMODULE hModule_;
	};

	static CompilerModuleHolder s_dllHolder;
} // anonymous namespace

namespace Moo {

// ----------------------------------------------------------------------------
// Section: EffectCompiler
// ----------------------------------------------------------------------------

EffectCompiler::StrDigestMap EffectCompiler::s_hashCache_;
SimpleMutex EffectCompiler::s_hashCacheMutex_;
BW::string EffectCompiler::s_fxoInfix_;
EffectCompiler::StringStringMap EffectCompiler::s_macros_;


/**
*	Constructor
*/
EffectCompiler::EffectCompiler( bool purgeResCache, bool debugSymbols ) :
	purgeResCache_( purgeResCache ),
	compileFlags_( debugSymbols ? D3DXSHADER_DEBUG : 0 )
{
}

/**
*	This method checks if the specified resource file is modified.
*	@param fxoName object file built from the fx file.
*	@param resName fx file.
*	@param outResDigest optional parameter, saves the MD5 hash
*						digest of resName.
*	@return true if the resource file or its includes has been 
*			updated and needs a recompile.
*/
bool EffectCompiler::checkModified( const BW::string& resName,
								  MD5::Digest* outResDigest )
{
	BW_GUARD;

	BW::string fxoName = EffectHelpers::fxoName( resName );
	BW::string path = BWResource::getFilePath( resName );

	if (purgeResCache_)
	{
		BWResource::instance().purge( resName, true );
		BWResource::instance().purge( fxoName, true );
		this->purgeCachedHash( resName );
	}

	includes_.resetDependencies();
	includes_.currentPath( path );

	//Check the .fxo for recompilation
	//1) check to see if the .fxo even exists
	//2) check if the stored checksum differs from the .fx
	//3) check if the stored checksum for any included files differ

	MD5::Digest resDigest;
	if (!this->hashResource( resName, resDigest ))
	{
		// If the .fx doesn't exist, see if the fxo exists.
		if (BWResource::fileExists( fxoName ))
		{
			return false; // If fxo exists but fx doesn't, just use the fxo.
		}
		else
		{
			DEBUG_MSG( "EffectCompiler::checkModified: "
				"Both .fx and .fxo are missing (%s)\n", 
				resName.c_str() );
			return false;
		}
	}

	if (outResDigest)
	{
		*outResDigest = resDigest;
	}

	DataSectionPtr pSection = BWResource::openSection( fxoName );
	if (!pSection)
	{
		return true; // fxo doesn't exist, build it.
	}


	//
	// See if the checksum stored in the .fxo 
	// differs to the .fx file's actual checksum
	DataSectionPtr hashDataSection = pSection->openSection( "hash" );
	if (!hashDataSection)
	{
		return true; // must be an old fxo, rebuild it.
	}

	BinaryPtr hashBin = hashDataSection->asBinary();
	IF_NOT_MF_ASSERT_DEV( hashBin != NULL )
	{
		return true;
	}

	BW::string quotedDigest;

	const char* pDigestValues =
		reinterpret_cast<const char*>( hashBin->data() );
	quotedDigest.assign( pDigestValues, pDigestValues + hashBin->len() );

	MD5::Digest storedResDigest;
	if (!storedResDigest.unquote( quotedDigest ))
	{
		return true; // bad data, rebuild it.
	}

	if (storedResDigest != resDigest)
	{
		return true; // there's a hash digest mismatch, rebuild it.
	}


	//
	// Go through and see if any of the dependancies have changed.
	DataSectionPtr effectDataSection = pSection->openSection( "effect" );
	if (!effectDataSection)
	{
		return true; // force recompile for old file
	}

	BW::vector< std::pair<BW::string, MD5::Digest> >::iterator itDep;
	BW::vector< std::pair<BW::string, MD5::Digest> > dependencies;

	// Go through and collect the dependancy list
	for (DataSectionIterator it = pSection->begin(); 
		it != pSection->end(); ++it)
	{
		DataSectionPtr pDS = *it;
		if (pDS->sectionName() == "depends")
		{
			// Grab the dependancy name
			DataSectionPtr nameDataSection = pDS->openSection( "name" );
			if ( !nameDataSection )
			{
				return true; // must be an old fxo, rebuild it.
			}

			BW::string depName;
			BinaryPtr pStringData = nameDataSection->asBinary();
			const char* pValues = 
				reinterpret_cast<const char*>( pStringData->data() );
			depName.assign( pValues, pValues + pStringData->len() );

			// Grab the stored dependancy hash
			DataSectionPtr hashDataSection = pDS->openSection( "hash" );
			if (!hashDataSection)
			{
				return true; // must be an old fxo, rebuild it.
			}

			BinaryPtr hashBin = hashDataSection->asBinary();
			IF_NOT_MF_ASSERT_DEV( hashBin != NULL )
			{
				return true;
			}

			BW::string quotedDigest;
			const char* pDigestValues = 
				reinterpret_cast<const char*>( hashBin->data() );
			quotedDigest.assign( pDigestValues, 
				pDigestValues + hashBin->len() );

			MD5::Digest storedDepDigest;
			if (! storedDepDigest.unquote(quotedDigest) )
			{
				return true; // bad data, rebuild it.
			}

			dependencies.push_back( std::make_pair(depName, storedDepDigest) );
		}
	}

	// Go through the dependancy list and see if any mismatch
	for (itDep = dependencies.begin(); 
		itDep != dependencies.end(); 
		++itDep)
	{
		BW::string name = (*itDep).first;		
		MD5::Digest storedDepDigest = (*itDep).second;

		BW::string pathName = includes_.resolveInclude( name );

		if (purgeResCache_)
		{
			BWResource::instance().purge( pathName, true );
			this->purgeCachedHash( pathName );
		}

		MD5::Digest depDigest;
		if (!this->hashResource( pathName, depDigest ))
		{
			return true; // If the dependency is missing then rebuild.
		}

		if ( depDigest != storedDepDigest )
		{
			return true; // If the dependency has changed then rebuild.
		}
	}

	// If we got this far, then we don't have to rebuild.
	return false;
}

/**
 *	This method takes the given effect resource ID and extracts all
 *  referenced includes
 *	NULL.
 */
bool EffectCompiler::getIncludes( const BW::string& resourceID,
								  BW::list< BW::string >& outResult )
{
	SimpleMutexHolder smh( mutex_ );

	BW::vector<D3DXMACRO> d3dxMacros;
	this->fillD3dxMacroArray( d3dxMacros );
	BW::string effectPath = BWResource::getFilePath( resourceID );
	includes_.currentPath( effectPath );
	includes_.resetDependencies();
	ComObjectWrap<ID3DXEffectCompiler> pCompiler;
	ComObjectWrap<ID3DXBuffer> pCompilationErrors;

	// Resolve the resource ID to an absolute file path.
	BW::string absFxPath = resourceID;
	BWResource::resolveToAbsolutePath( absFxPath );
	const BW::string& fxPath = !absFxPath.empty() ? absFxPath : resourceID;
	BW::wstring wResName = bw_utf8tow( fxPath );
	HRESULT hr = D3DXCreateEffectCompilerFromFileW( wResName.c_str(),
		&d3dxMacros[0],
		&includes_,
		compileFlags_ | USE_LEGACY_D3DX9_DLL, &pCompiler,
		&pCompilationErrors );


	//-- if we failed to create legacy HLSL compiler then try to create standard
	//--	 DX10 compiler. This may happens only when we try to compile SM 3.0 shaders. As
	//--	 legacy compiler may deal only with SM 1.0 - 2.0 and just a little with SM 3.0.
	//--	 For example legacy complier doesn't support conditional expressions for SM 3.0
	//--	 like beak, continue and so on.
	if (FAILED(hr))
	{
		hr = D3DXCreateEffectCompilerFromFileW( wResName.c_str(),
			&d3dxMacros[0],
			&includes_,
			compileFlags_, &pCompiler,
			&pCompilationErrors );
	}

	if (FAILED( hr ))
	{
		ERROR_MSG( "%s\n", pCompilationErrors ? 
			pCompilationErrors->GetBufferPointer() : "" );

		return false;
	}

	EffectIncludes::StringList& includes = includes_.dependencies();
	for (EffectIncludes::StringList::iterator
		it = includes.begin(); it != includes.end(); ++it)
	{
		BW::string include = includes_.resolveInclude( *it );
		if (include != resourceID)
		{
			outResult.push_back( include );
		}
	}
	return true;
}

/**
 *	This method takes the given effect resource ID and compiles it to disk.
 *	The compiled effect binary is returned, or NULL if there was a failure.
 *	Compiler results are written into the given result string, if it isn't 
 *	NULL.
 */
BinaryPtr EffectCompiler::compile( const BW::string& resourceID,
								   BW::string* outResult,
								   BW::string* fxoResourceID )
{
	// Prevent simultaneous shader compilation in multiple threads.
	//
	// EffectIncludes is not thread safe despite the fact we allow 
	// compilation in different threads - for example when pre-loading
	// (main thread) or streaming (loading thread).
	//
	// Compiling in both threads simultaneously probably means the calling 
	// code is doing something wrong. In this case we stall the thread and 
	// wait for previous compilation to finish.
	SimpleMutexHolder smh( mutex_ );

	ComObjectWrap<ID3DXEffect> pEffect;
	ComObjectWrap<ID3DXBuffer> pCompilationErrors;

	BW::vector<D3DXMACRO> d3dxMacros;
	this->fillD3dxMacroArray( d3dxMacros );

	BW::string fxoName = fxoResourceID != NULL ? *fxoResourceID : EffectHelpers::fxoName( resourceID );

	// Set include path
	BW::string effectPath = BWResource::getFilePath( resourceID );
	includes_.currentPath( effectPath );
	includes_.resetDependencies();

	// Check if the file or any of its dependents have been modified.
	MD5::Digest resDigest;
	bool recompile = true;

	if (!this->hashResource( resourceID, resDigest ))
	{
		fxDebugLog( "EffectCompiler::compile: failed to hash '%s'\n",
			resourceID.c_str() );
		DEBUG_MSG( "EffectCompiler::compile: failed to hash '%s'.\n",
			resourceID.c_str() );
		return NULL;
	}

	BinaryPtr bin;
	if (recompile)
	{
		fxDebugLog( "EffectCompiler::compile: compiling '%s'\n",
			resourceID.c_str() );
		TRACE_MSG( "EffectCompiler: compiling '%s'\n",
			resourceID.c_str() );

		ComObjectWrap<ID3DXEffectCompiler> pCompiler;

		// Resolve the resource ID to an absolute file path so that
		// D3DXCreateEffectCompilerFromFileW can find the .fx file
		// regardless of the current working directory.
		BW::string absFxPath = resourceID;
		IFileSystem::FileType ft = BWResource::resolveToAbsolutePath( absFxPath );
		fxDebugLog( "EffectCompiler::compile: resolved '%s' -> '%s' (type=%d)\n",
			resourceID.c_str(), absFxPath.c_str(), (int)ft );
		const BW::string& fxPath = !absFxPath.empty() ? absFxPath : resourceID;
		BW::wstring wResName = bw_utf8tow( fxPath );
		HRESULT hr = D3DXCreateEffectCompilerFromFileW( wResName.c_str(),
			&d3dxMacros[0],
			&includes_,
			compileFlags_ | USE_LEGACY_D3DX9_DLL, &pCompiler,
			&pCompilationErrors );

		fxDebugLog( "EffectCompiler::compile: D3DXCreateEffectCompiler (legacy) hr=0x%08X\n", hr );

		//-- if we failed to create legacy HLSL compiler then try to create standard
		//--	 DX10 compiler. This may happens only when we try to compile SM 3.0 shaders. As
		//--	 legacy compiler may deal only with SM 1.0 - 2.0 and just a little with SM 3.0.
		//--	 For example legacy complier doesn't support conditional expressions for SM 3.0
		//--	 like beak, continue and so on.
		if (FAILED(hr))
		{
			hr = D3DXCreateEffectCompilerFromFileW( wResName.c_str(),
				&d3dxMacros[0],
				&includes_,
				compileFlags_, &pCompiler,
				&pCompilationErrors );
			fxDebugLog( "EffectCompiler::compile: D3DXCreateEffectCompiler (standard) hr=0x%08X\n", hr );
		}

		if (FAILED( hr ))
		{
			fxDebugLog( "EffectCompiler::compile: FAILED to create compiler for '%s'\n", resourceID.c_str() );
			if (pCompilationErrors)
			{
				fxDebugLog( "EffectCompiler::compile: errors: %s\n",
					(char*)pCompilationErrors->GetBufferPointer() );
			}
			ERROR_MSG( "%s\n", pCompilationErrors ?
				pCompilationErrors->GetBufferPointer() : "" );

			if (outResult)
			{
				*outResult = pCompilationErrors ?
					(char*)pCompilationErrors->GetBufferPointer() :
				"Unable to create effect compiler.";
			}

			return NULL;
		}

		IF_NOT_MF_ASSERT_DEV( pCompiler != NULL )
		{
			return NULL;
		}

		ComObjectWrap<ID3DXBuffer> pEffectBuffer;
		{
#ifdef EDITOR_ENABLED
			SlowTask st;
#endif//EDITOR_ENABLED
			hr = pCompiler->CompileEffect( compileFlags_, &pEffectBuffer,
				&pCompilationErrors );
		}
		fxDebugLog( "EffectCompiler::compile: CompileEffect hr=0x%08X\n", hr );
		if (FAILED( hr ))
		{
			fxDebugLog( "EffectCompiler::compile: CompileEffect FAILED for '%s'\n", resourceID.c_str() );
			if (pCompilationErrors)
			{
				fxDebugLog( "EffectCompiler::compile: errors: %s\n",
					(char*)pCompilationErrors->GetBufferPointer() );
			}
			ASSET_MSG( "ManagedEffect::compile - "
				"Unable to compile effect %s\n%s",
				resourceID.c_str(),
				pCompilationErrors ?
					pCompilationErrors->GetBufferPointer() : "" );

			if (outResult)
			{
				*outResult = pCompilationErrors ?
					(char*)pCompilationErrors->GetBufferPointer():
				"Unable to compile effect.";
			}

			return NULL;
		}
		else
		{
			if (outResult)
			{
				*outResult = "Compilation successful.";
			}
		}

		bin = new BinaryBlock( pEffectBuffer->GetBufferPointer(),
			pEffectBuffer->GetBufferSize(), "BinaryBlock/ManagedEffect" );

		// Try to save the compiled .fxo for caching. If saving fails
		// (e.g. read-only resource path), the compiled binary (bin) is
		// still valid and returned to the caller. Wrap in an IIFE so
		// that any save-related failure just exits the lambda without
		// discarding the already-compiled bin.
		[&]()
		{
		BWResource::instance().fileSystem()->eraseFileOrDirectory(
			fxoName );

		// create the new section
		DataSectionPtr pSection = NULL;
		DataSectionPtr parentSection = NULL;
		BW::string::size_type lastSep = fxoName.find_last_of( '/' );
		BW::string parentName = fxoName.substr( 0, lastSep );
		BW::string tagName = fxoName.substr( lastSep + 1 );

		static SimpleMutex parentSectionMutex;
		{
			// Protect modification of the parent section with a mutex
			SimpleMutexHolder parentSectionSMH( parentSectionMutex );

			parentSection = BWResource::openSection(
			parentName, true, ZipSection::creator() );
		if (!parentSection)
		{
			fxDebugLog( "EffectCompiler::compile: could not open parent section '%s' for save, skipping save\n",
				parentName.c_str() );
			return;
		}

		// make it
		pSection = parentSection->openSection(
			tagName, true, ZipSection::creator() );
	}

	pSection->setParent( parentSection );
	pSection = pSection->convertToZip( "", parentSection );

	if (!pSection)
	{
		fxDebugLog( "EffectCompiler::compile: convertToZip failed, skipping save\n" );
		return;
	}

		pSection->delChildren();

		DataSectionPtr effectSection =
			pSection->openSection( "effect", true );
		effectSection->setParent( pSection );

		DataSectionPtr hashSection =
			pSection->openSection( "hash", true );
		hashSection->setParent( pSection );

		BW::string quotedResDigest = resDigest.quote();

		BinaryPtr resDigestBinaryBlock =
			new BinaryBlock(
			quotedResDigest.data(),
			quotedResDigest.length(),
			"BinaryBlock/ManagedEffect" );

		pSection->writeBinary( "hash", resDigestBinaryBlock );

		bool warn = true;

		if (pSection->writeBinary( "effect", bin ))
		{
			// Write the dependency list
			BW::list<BW::string> &src =
				includes_.dependencies();
			src.unique(); // remove possible duplicates..

			for (BW::list<BW::string>::iterator it = src.begin();
				it != src.end(); ++it)
			{
				DataSectionPtr dependsSec = pSection->newSection("depends");
				DataSectionPtr dependsNameSec = dependsSec->newSection("name");

				BW::string str( *it );

				BinaryPtr binaryBlockString =
					new BinaryBlock(
					str.data(),
					str.size(),
					"BinaryBlock/ManagedEffect" );
				dependsNameSec->setBinary( binaryBlockString );


				// resolve the include and store its hash.
				BW::string pathname = includes_.resolveInclude( str );

				MD5::Digest depDigest;
				bool hashed = this->hashResource(
					pathname, depDigest );

				if (!hashed)
				{
					fxDebugLog( "EffectCompiler::compile: skipping unhashable dependency '%s'\n",
						pathname.c_str() );
					continue;
				}

				BW::string quotedDepDigest = depDigest.quote();

				DataSectionPtr depHashSection = dependsSec->newSection( "hash" );
				BinaryPtr depDigestBinaryBlock =
					new BinaryBlock(
					quotedDepDigest.data(),
					quotedDepDigest.length(),
					"BinaryBlock/ManagedEffect" );

				depHashSection->setBinary( depDigestBinaryBlock );
			}

			// Now actually save...
			if (!pSection->save())
			{
				// It failed, but it might be because it's running from Zip(s)
				// file(s). If so, there should be a writable, cache directory
				// in the search paths, so try to build the folder structure in
				// it and try to save again.
				BWResource::ensurePathExists( effectPath );
				warn = !pSection->save();
			}
			else
			{
				warn = false;
			}
		}

		if (warn)
		{
			BW::string msg = "Could not save recompiled " + fxoName + ".";
			WARNING_MSG( "%s\n", msg.c_str() );

			if (outResult)
			{
				*outResult = msg;
			}
		}

		hashSection->setParent( NULL );
		effectSection->setParent( NULL );
		effectSection = NULL;
		hashSection = NULL;
		pSection = NULL;
		parentSection = NULL;
		}(); // end save IIFE
	}
	else
	{
		bin = EffectHelpers::loadEffectBinary( resourceID );

		if (bin && outResult)
		{
			*outResult = "Up to date.";
		}
	}

	fxDebugLog( "EffectCompiler::compile: returning bin=%p for '%s'\n",
		(void*)bin.getObject(), resourceID.c_str() );
	return bin;
}

/**
 *	Generate the array of preprocessor definitions.
 */
// static
void EffectCompiler::fillD3dxMacroArray( BW::vector<D3DXMACRO>& result )
{
	BW_GUARD;
	result.reserve( s_macros_.size()+2 );

	StringStringMap::const_iterator macroIt  = s_macros_.begin();
	StringStringMap::const_iterator macroEnd = s_macros_.end();
	while (macroIt != macroEnd)
	{	
		D3DXMACRO d3dxMacro = { 
			macroIt->first.c_str(),
			macroIt->second.c_str()
		};
		result.push_back( d3dxMacro );
		++macroIt;
	}

	D3DXMACRO inGame = { "IN_GAME", "true" };
	D3DXMACRO nullTerminator = { NULL, NULL };
	result.push_back( inGame );
	result.push_back( nullTerminator );
}

/**
 *	Calculates the MD5 hash for the given resource.
 */
// static
bool EffectCompiler::hashResource( const BW::string& name, 
								  MD5::Digest& result )
{
	BW_GUARD;
	SimpleMutexHolder smh( s_hashCacheMutex_ );

	StrDigestMap::iterator it = s_hashCache_.find( name );
	if (it != s_hashCache_.end())
	{
		result = it->second;
		return true;
	}


	DataSectionPtr ds = BWResource::openSection( name );
	if (!ds)
	{
		return false;
	}

	BinaryPtr data = ds->asBinary();
	if (!data)
	{
		return false;
	}

	MD5 md5;
	md5.append( data->data(), (int)data->len() );
	md5.getDigest( result );

	s_hashCache_[ name ] = result;
	return true;
}

/**
 *	Purges the given name out of the hash cache.
 */
// static
void EffectCompiler::purgeCachedHash( const BW::string& name )
{
	BW_GUARD;
	SimpleMutexHolder smh( s_hashCacheMutex_ );
	StrDigestMap::iterator it = s_hashCache_.find( name );
	if (it != s_hashCache_.end())
	{
		s_hashCache_.erase( it );
	}
}

/**
*	Sets effect file compile time macro definition.
*
*	@param	macro	macro name.
*	@param	value	macro value.
*/
// static
void EffectCompiler::setMacroDefinition( const BW::string & macro, 
							const BW::string & value )
{
	s_macros_[macro] = value;
}

/**
 *	Gets the current FXO infix (based on effect macro settings).
 */
// static
const BW::string& EffectCompiler::fxoInfix()
{
	return s_fxoInfix_;
}

/**
 *	Sets the current FXO infix (based on effect macro settings).
 */
// static
void EffectCompiler::fxoInfix( const BW::string & infix )
{
	s_fxoInfix_ = infix;
}

} // namespace Moo

BW_END_NAMESPACE

// effect_compiler.cpp
