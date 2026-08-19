'''This module contains constant data associated with the Guard entity type.
'''

import ResMgr
import AvatarModel
import CustomisableModel

# Check if ResMgr.openSection is available (it may not be in all server apps)
_HAS_OPEN_SECTION = hasattr(ResMgr, 'openSection')

# Guard Type Enumerations
HIGHLANDS_GUARD = 0
DEPRECATED_GUARD = 1
MINSPEC_GUARD = 2


GUARD_TYPES = {
	HIGHLANDS_GUARD:'Highlands Guard',
	DEPRECATED_GUARD:'deprecated',
	MINSPEC_GUARD:'Minspec Guard'
}

GUARD_SHOWNAMES = {
	HIGHLANDS_GUARD:'Guard',
	DEPRECATED_GUARD:'deprecated',
	MINSPEC_GUARD:'Guard',
}

GUARD_MODELS = {}

def load():
	if not _HAS_OPEN_SECTION:
		print "GuardData: ResMgr.openSection not available, skipping load"
		return
	for model in CustomisableModel.load( ResMgr.openSection( "scripts/data/guard_model_data.xml" ) ):
		try:
			GUARD_MODELS[GUARD_TYPES.values().index( model.name )] = model
		except ValueError:
			print "ASSET ERROR: Base model '%s' not in GUARD_TYPES" % model.name

	for guardType in GUARD_TYPES:
		if guardType not in GUARD_MODELS:
			print "ASSET ERROR: No base model in guard_model_data.xml for guard type '%s'" % guardType

load()
