#ifndef ALCONFIG_H
#define ALCONFIG_H

#include <string>

#include "aloptional.h"

void ReadALConfig();

int ConfigValueExists(const char *devName, const char *blockName, const char *keyName);
const char *GetConfigValue(const char *devName, const char *blockName, const char *keyName, const char *def);
int GetConfigValueBool(const char *devName, const char *blockName, const char *keyName, int def);

al::optional<std::string> ConfigValueStr(const char *devName, const char *blockName, const char *keyName);
al::optional<int> ConfigValueInt(const char *devName, const char *blockName, const char *keyName);
al::optional<unsigned int> ConfigValueUInt(const char *devName, const char *blockName, const char *keyName);
al::optional<float> ConfigValueFloat(const char *devName, const char *blockName, const char *keyName);
al::optional<bool> ConfigValueBool(const char *devName, const char *blockName, const char *keyName);

#endif /* ALCONFIG_H */
