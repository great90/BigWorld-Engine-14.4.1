#include "pch.hpp"
#include "effect_helpers.hpp"
#include "effect_compiler.hpp"
#include <cstdio>

BW_BEGIN_NAMESPACE

namespace Moo {
	namespace EffectHelpers {

	// Simple debug log for early init diagnostics (before main logger is ready)
	static void debugLog( const char* fmt, ... )
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

	/**
	 *	
	 */
	BW::string fxoName( const BW::string& resourceID )
	{
		BW_GUARD;
		BW::StringRef fileName   = BWResource::removeExtension( resourceID );
		BW::string objectName = !EffectCompiler::fxoInfix().empty() 
			? fileName + "." + EffectCompiler::fxoInfix() + ".fxo"
			: fileName + ".fxo";

		return objectName;
	}


	/**
	 *	
	 */
	bool fxName( const StringRef& resourceID, BW::string & effectResource )
	{
		BW_GUARD;
		BW::StringRef fileName = BWResource::removeExtension( resourceID );
		BW::StringRef infix = BWResource::getExtension( fileName );
		if (!EffectCompiler::fxoInfix().empty())
		{
			if (infix != EffectCompiler::fxoInfix())
			{
				return false;
			}
			fileName = BWResource::removeExtension( fileName );
		}
		else if (!infix.empty())
		{
			return false;
		}

		effectResource = fileName + ".fx";
		return true;
	}


	/**
	 *	
	 */
	BinaryPtr loadEffectBinary( const BW::string& resourceID )
	{
		BW_GUARD;
#if EDITOR_ENABLED
		MF_ASSERT( BWResource::instance().pathIsRelative( resourceID ) );
#endif
		BW::string fxoName = EffectHelpers::fxoName( resourceID );

		DataSectionPtr pSection =
			BWResource::instance().rootSection()->openSection( fxoName );
		BWResource::instance().purge( fxoName, true );

		if (pSection)
		{
			return pSection->readBinary( "effect" );
		}
		else
		{
			debugLog( "loadEffectBinary: .fxo not found for '%s', trying runtime compile\n",
				resourceID.c_str() );

			// Fallback: compile the .fx at runtime if .fxo is not found.
			EffectCompiler compiler( false, false );
			BW::string compileResult;
			BinaryPtr bin = compiler.compile( resourceID, &compileResult );

			debugLog( "loadEffectBinary: compile result for '%s' = %s, bin=%p, msg='%s'\n",
				resourceID.c_str(),
				bin ? "SUCCESS" : "FAILED",
				(void*)bin.getObject(),
				compileResult.c_str() );

			if (bin)
			{
				return bin;
			}
			ASSET_MSG( "EffectHelpers::loadEffectBinary: "
				"unable to load or compile effect '%s' (%s)\n",
				fxoName.c_str(), compileResult.c_str() );
			return NULL;
		}
	}

	} // namespace EffectHelpers
} // namespace Moo

BW_END_NAMESPACE

// effect_helpers.cpp
