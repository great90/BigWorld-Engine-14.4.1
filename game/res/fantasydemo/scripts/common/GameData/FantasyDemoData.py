# This module contains constant data used by the FantasyDemo module that is
# loaded from xml. The data is loaded from entities/data/fantasy_demo.xml
# and the space.settings of the default space.
# Note: For the moment all data loaded by this module should be client safe.

import ResMgr
import Math

# Check if ResMgr.openSection is available (it may not be in all server apps)
_HAS_OPEN_SECTION = hasattr(ResMgr, 'openSection')

CONFIG_FILE = 'scripts/data/fantasy_demo.xml'
REALMS = {}
DEFAULT_REALM_NAME = None

class RealmSpace:
	def __init__( self, path ):
		self.path = path
		self.startPosition = Math.Vector3( 0,0,0 )
		if _HAS_OPEN_SECTION:
			ds = ResMgr.openSection( path )
			if ds is not None:
				self.startPosition = ds.readVector3( 'space.settings/startPosition' )
			else:
				print "ERROR: space.settings not found for '%s'" % path

class Realm:
	def __init__( self, ds ):
		self.name = ds._name.asString
		self.displayName = ds._displayName.asWideString
		self.spaces = [ RealmSpace(x) for x in ds._spaces.readStrings( 'space' ) ]


def initRealms():
	global DEFAULT_REALM_NAME
	if not _HAS_OPEN_SECTION:
		print "FantasyDemoData: ResMgr.openSection not available, skipping initRealms"
		return
	for realmDS in [ v for v in ResMgr.openSection( CONFIG_FILE+'/realms' ).values() if v.name == 'realm' ]:
		realm = Realm( realmDS )

		if not DEFAULT_REALM_NAME:
			DEFAULT_REALM_NAME = realm.name

		if realm.name not in REALMS:
			REALMS[ realm.name ] = realm
		else:
			print "ERROR: Conflicting realm id '%s'" % realm.name


if _HAS_OPEN_SECTION:
	OFFLINE_MODE_IGNORED_SPACES = ResMgr.openSection( CONFIG_FILE+'/offlineModeIgnoredSpaces' ).readStrings( "space" )
else:
	OFFLINE_MODE_IGNORED_SPACES = []

initRealms()
