#ifndef ALEXCPT_H
#define ALEXCPT_H

#include <cstdarg>
#include <exception>
#include <string>
#include <utility>

#include "AL/alc.h"


namespace al {

class base_exception : public std::exception {
    std::string mMessage;
    ALCenum mErrorCode;

protected:
    base_exception(ALCenum code) : mErrorCode{code} { }
    virtual ~base_exception();

    void setMessage(const char *msg, std::va_list args);

public:
    const char *what() const noexcept override { return mMessage.c_str(); }
    ALCenum errorCode() const noexcept { return mErrorCode; }
};

} // namespace al

#define START_API_FUNC try

#define END_API_FUNC catch(...) { std::terminate(); }

#endif /* ALEXCPT_H */
