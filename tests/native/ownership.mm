#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static void require(bool condition, const char* message)
{
    if (!condition)
    {
        std::fprintf(stderr, "ownership regression: %s\n", message);
        std::abort();
    }
}

static std::map<PA_Unichar*, size_t> strings;
static std::map<PA_Handle, size_t> handles;
struct TestPicture
{
    unsigned refs;
    unsigned value;
};
static std::map<PA_Picture, TestPicture*> pictures;
static bool allocatedEmpty;
static CUTF16String expectedText;
static unsigned commands;

static PA_Unistring makeString(const PA_Unichar* text)
{
    const size_t length = text ? PA_GetUnicharsLength(const_cast<PA_Unichar*>(text)) : 0;
    PA_Unistring result = {};
    if (length || allocatedEmpty)
    {
        PA_Unichar* buffer = static_cast<PA_Unichar*>(std::malloc((length + 1) * sizeof(PA_Unichar)));
        require(buffer != nullptr, "fixture string allocation");
        strings[buffer] = length;
        result.fString = buffer;
        if (length)
            std::memcpy(result.fString, text, length * sizeof(PA_Unichar));
        result.fString[length] = 0;
    }
    result.fLength = static_cast<PA_long32>(length);
    return result;
}

static void checkString(const PA_Unistring& value, const CUTF16String& expected)
{
    require(value.fLength == expected.size(), "exact UTF-16 length");
    if (value.fString)
    {
        const PA_Unichar* buffer = value.fString;
        const auto found = strings.find(const_cast<PA_Unichar*>(buffer));
        require(found != strings.end(), "string is still owned and live");
        require(found->second == expected.size(), "string capacity in code units");
        require(value.fString[value.fLength] == 0, "string terminator");
        require(CUTF16String(value.fString, value.fLength) == expected, "exact UTF-16 content");
    }
    else
        require(expected.empty(), "null buffer only represents empty text");
}

static void freeString(PA_Unistring& value)
{
    if (value.fString)
    {
        PA_Unichar* buffer = value.fString;
        require(strings.erase(buffer) == 1, "double disposal or borrowed string disposal");
        std::free(buffer);
    }
    value = {};
}

static PA_Picture makePicture(unsigned value = 42)
{
    TestPicture* picture = new TestPicture{1, value};
    pictures[picture] = picture;
    return picture;
}

static TestPicture* checkPicture(PA_Picture value)
{
    const auto found = pictures.find(value);
    require(found != pictures.end(), "picture handoff remains live");
    require(found->second->refs > 0 && found->second->value == 42, "picture content and reference");
    return found->second;
}

static void freePicture(PA_Picture value)
{
    if (value)
    {
        TestPicture* picture = checkPicture(value);
        if (--picture->refs == 0)
        {
            pictures.erase(value);
            delete picture;
        }
    }
}

static void clear(PA_Variable& value)
{
    switch (value.fType)
    {
        case eVK_Unistring:
            freeString(value.uValue.fString);
            break;
        case eVK_Picture:
            freePicture(value.uValue.fPicture);
            break;
        case eVK_ArrayUnicode:
        {
            const PA_Handle data = value.uValue.fArray.fData;
            if (data)
            {
                require(handles.count(data) == 1, "array handle is live");
                PA_Unistring* elements = reinterpret_cast<PA_Unistring*>(*data);
                for (PA_long32 i = 0; i <= value.uValue.fArray.fNbElements; ++i)
                    freeString(elements[i]);
                PA_DisposeHandle(data);
            }
            break;
        }
        case eVK_Undefined:
        case eVK_Longint:
            break;
        default:
            require(false, "unexpected variable kind at engine clear boundary");
    }
    value = {};
    value.fType = eVK_Undefined;
}

static void handleManager(EngineBlock* eb)
{
    eb->fError = 0;
    const sLONG_PTR size = (eb->fParam1 == 1 || eb->fParam1 == 3) ? eb->fParam2 : 0;
    if (eb->fParam1 == 1)
    {
        require(eb->fParam2 >= 0, "nonnegative handle size");
        PA_Handle handle = static_cast<PA_Handle>(std::malloc(sizeof(char*)));
        require(handle != nullptr, "fixture handle allocation");
        *handle = static_cast<char*>(std::malloc(std::max<sLONG_PTR>(1, size)));
        require(*handle != nullptr, "fixture handle data allocation");
        handles[handle] = eb->fParam2;
        eb->fHandle = handle;
        return;
    }
    const PA_Handle handle = eb->fHandle;
    require(handles.count(handle) == 1, "live handle at engine boundary");
    switch (eb->fParam1)
    {
        case 2:
            std::free(*eb->fHandle);
            std::free(eb->fHandle);
            handles.erase(handle);
            break;
        case 3:
        {
            require(eb->fParam2 >= 0, "nonnegative resize");
            char* data = static_cast<char*>(std::realloc(*eb->fHandle, std::max<sLONG_PTR>(1, size)));
            require(data != nullptr, "fixture handle resize");
            *eb->fHandle = data;
            handles[handle] = eb->fParam2;
            break;
        }
        case 4:
            eb->fParam2 = handles.at(handle);
            break;
        case 5:
            eb->fParam3 = reinterpret_cast<sLONG_PTR>(*eb->fHandle);
            break;
        case 6:
            break;
        default:
            require(false, "unexpected handle operation");
    }
}

static void convert(EngineBlock* eb)
{
    require(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16,
            "expected charset conversion");
    CFStringRef text = CFStringCreateWithBytes(kCFAllocatorDefault,
        static_cast<const UInt8*>(eb->fPtr1), eb->fParam1, kCFStringEncodingUTF8, false);
    require(text != nullptr, "valid UTF-8 conversion fixture");
    const CFIndex units = CFStringGetLength(text);
    const CFIndex bytes = units * sizeof(PA_Unichar);
    require(bytes <= eb->fParam3, "conversion capacity is bytes, not UTF-16 units");
    // The engine reports bytes written; the pre-zeroed caller buffer supplies termination.
    CFStringGetCharacters(text, CFRangeMake(0, units), static_cast<UniChar*>(eb->fPtr2));
    eb->fParam3 = bytes;
    eb->fError = 0;
    CFRelease(text);
}

static void replacePicture(PA_Variable& value)
{
    clear(value);
    value.fType = eVK_Picture;
    value.uValue.fPicture = makePicture();
}

static void execute(EngineBlock* eb)
{
    ++commands;
    PA_Variable** args = static_cast<PA_Variable**>(eb->fPtr1);
    PA_Variable* returned = static_cast<PA_Variable*>(eb->fPtr2);
    require(returned->fType == eVK_Undefined, "procedure has no returned owner");
    switch (eb->fParam1)
    {
        case 678:
            require(eb->fParam2 == 2, "READ PICTURE FILE argument count");
            checkString(args[0]->uValue.fString, expectedText);
            replacePicture(*args[1]);
            break;
        case 1002:
            checkString(args[1]->uValue.fString, expectedText);
            checkPicture(args[0]->uValue.fPicture);
            replacePicture(*args[0]);
            break;
        case 988:
            require(args[1]->uValue.fLongint == 101, "grayscale transform");
            checkPicture(args[0]->uValue.fPicture);
            replacePicture(*args[0]);
            break;
        case 457:
            checkPicture(args[0]->uValue.fPicture);
            PA_SetLongintVariable(args[1], 13);
            PA_SetLongintVariable(args[2], 17);
            break;
        case 679:
            checkPicture(args[0]->uValue.fPicture);
            require(args[2]->uValue.fLongint == 13 && args[3]->uValue.fLongint == 17,
                    "thumbnail dimensions");
            replacePicture(*args[1]);
            break;
        default:
            require(false, "unexpected command");
    }
    eb->fError = 0;
}

static pascal void engine(short selector, EngineBlock* eb)
{
    switch (selector)
    {
        case EX_HANDLE_MANAGER:
            handleManager(eb);
            break;
        case EX_CREATE_UNISTRING:
            eb->fUniString1 = makeString(reinterpret_cast<PA_Unichar*>(eb->fHandle));
            break;
        case EX_DISPOSE_UNISTRING:
            freeString(eb->fUniString1);
            break;
        case EX_SET_UNISTRING:
        {
            PA_Unistring copy = makeString(reinterpret_cast<PA_Unichar*>(eb->fHandle));
            freeString(eb->fUniString1);
            eb->fUniString1 = copy;
            break;
        }
        case EX_CREATE_PICTURE:
            eb->fPicture = makePicture();
            eb->fError = 0;
            break;
        case EX_DISPOSE_PICTURE:
            freePicture(eb->fPicture);
            break;
        case EX_DUPLICATE_PICTURE:
            require(eb->fParam1 == 0, "retainOnly is inverted by the SDK");
            if (eb->fPicture)
                ++checkPicture(eb->fPicture)->refs;
            break;
        case EX_GET_PICTURE_DATA:
            // No representations. Failed output is deliberately unspecified and must not be used.
            checkPicture(eb->fPicture);
            eb->fError = eER_IncompatibleTypes;
            break;
        case EX_CLEAR_VARIABLE:
            clear(*static_cast<PA_Variable*>(eb->fPtr1));
            break;
        case EX_CONVERT_CHARSET_TO_CHARSET:
            convert(eb);
            break;
        case EX_EXECUTE_COMMAND_BY_ID:
            execute(eb);
            break;
        case EX_YIELD_ABSOLUTE:
            break;
        default:
            std::fprintf(stderr, "unexpected engine selector: %d\n", selector);
            std::abort();
    }
}

static void balanced()
{
    require(strings.empty(), "leaked string owner (including allocated empty)");
    require(handles.empty(), "leaked handle owner");
    require(pictures.empty(), "leaked picture reference or overwritten initial empty picture");
}

static const std::vector<std::vector<PA_Unichar>> fixtures = {
    {'A', 'S', 'C', 'I', 'I', 0},
    {0x65e5, 0x672c, 0},
    {'x', 0xd83d, 0xde00, 0},
    {0}
};

static CUTF8String utf8(const CUTF16String& text)
{
    C_TEXT converted;
    converted.setUTF16String(text.c_str(), text.size());
    CUTF8String result;
    converted.copyUTF8String(&result);
    return result;
}

static void filePath()
{
    for (const auto& fixture : fixtures)
    {
        expectedText = CUTF16String(fixture.data());
        CUTF8String path = utf8(expectedText);
        {
            CPicture picture;
            picture.fromFileAtPath(&path);
            checkPicture(picture.getPicture());
            require(checkPicture(picture.getPicture())->refs == 1, "file output has one retained owner");
            picture.fromFileAtPath(&path);
            checkPicture(picture.getPicture());
        }
        balanced();
    }
}

static void bytes()
{
    {
        CPicture picture;
        const uint8_t data[] = {1, 2, 3};
        picture.setBytes(data, sizeof(data));
        require(checkPicture(picture.getPicture())->refs == 1, "setBytes releases temporary owner");
        picture.setBytes(data, sizeof(data));
        picture.setBytes(nullptr, 0);
    }
    balanced();
}

static void pictureCommands(const std::string& scenario)
{
    for (const auto& fixture : fixtures)
    {
        PA_Picture output = nullptr;
        {
            CPicture picture;
            if (scenario == "copy")
            {
                expectedText = CUTF16String(fixture.data());
                CUTF8String format = utf8(expectedText);
                output = picture.createCopy(reinterpret_cast<const char*>(format.c_str()));
            }
            else if (scenario == "gray")
                output = picture.createGrayScale();
            else if (scenario == "thumbnail")
                output = picture.createThumbnail(13, 17);
            else
            {
                unsigned width = 0, height = 0;
                picture.getSize(&width, &height);
                require(width == 13 && height == 17, "property values copied before argument clear");
                require(checkPicture(picture.getPicture())->refs == 1, "borrowed property input not consumed");
            }
            if (output)
                require(checkPicture(output)->refs == 1, "owning picture handoff");
        }
        if (output)
        {
            checkPicture(output);
            PA_DisposePicture(output);
        }
        balanced();
    }
}

static void arrays()
{
    PA_Variable array = PA_CreateVariable(eVK_ArrayUnicode);
    PA_ResizeArray(&array, fixtures.size() - 1);
    for (size_t i = 0; i < fixtures.size(); ++i)
    {
        PA_Unistring text = PA_CreateUnistring(const_cast<PA_Unichar*>(fixtures[i].data()));
        PA_SetStringInArray(array, i, &text);
        require(PA_GetStringInArray(array, i).fString == text.fString, "accepted setter shallow-transfers");
    }
    BytePtr parameters[] = {reinterpret_cast<BytePtr>(&array)};
    ARRAY_TEXT copy;
    copy.fromParamAtIndex(parameters, 1);
    PA_ClearVariable(&array);
    balanced();
    array = PA_CreateVariable(eVK_Undefined);
    copy.toParamAtIndex(parameters, 1);
    for (size_t i = 0; i < fixtures.size(); ++i)
        checkString(PA_GetStringInArray(array, i), CUTF16String(fixtures[i].data()));
    PA_Variable other = PA_CreateVariable(eVK_ArrayUnicode);
    BytePtr otherParameters[] = {reinterpret_cast<BytePtr>(&other)};
    copy.toParamAtIndex(otherParameters, 1);
    for (size_t i = 0; i < fixtures.size(); ++i)
    {
        PA_Unistring first = PA_GetStringInArray(array, i);
        PA_Unistring second = PA_GetStringInArray(other, i);
        if (first.fString)
            require(first.fString != second.fString, "independent transferred output owners");
    }
    copy.toParamAtIndex(parameters, 1);
    PA_ResizeArray(&array, 0);
    PA_ClearVariable(&array);
    for (size_t i = 0; i < fixtures.size(); ++i)
        checkString(PA_GetStringInArray(other, i), CUTF16String(fixtures[i].data()));
    PA_ClearVariable(&other);
    balanced();

    PA_Unistring owned = PA_CreateUnistring(const_cast<PA_Unichar*>(fixtures[0].data()));
    PA_Variable wrong = PA_CreateVariable(eVK_Longint);
    PA_SetStringInArray(wrong, 0, &owned);
    array = PA_CreateVariable(eVK_ArrayUnicode);
    PA_SetStringInArray(array, -1, &owned);
    PA_SetStringInArray(array, 1, &owned);
    PA_SetStringInArray(array, 0, nullptr);
    PA_Variable missing = {};
    missing.fType = eVK_ArrayUnicode;
    PA_SetStringInArray(missing, 0, &owned);
    checkString(owned, CUTF16String(fixtures[0].data()));
    PA_DisposeUnistring(&owned);
    PA_ClearVariable(&array);
    PA_ClearVariable(&wrong);
    PA_Unistring nullEmpty = {};
    array = PA_CreateVariable(eVK_ArrayUnicode);
    PA_SetStringInArray(array, 0, &nullEmpty);
    checkString(PA_GetStringInArray(array, 0), CUTF16String());
    PA_ClearVariable(&array);
    balanced();
}

static void scalars()
{
    for (const auto& fixture : fixtures)
    {
        C_TEXT text;
        text.setUTF16String(fixture.data(), fixture.size() - 1);
        PA_Unistring output = {};
        BytePtr parameters[] = {reinterpret_cast<BytePtr>(&output)};
        text.toParamAtIndex(parameters, 1);
        checkString(output, CUTF16String(fixture.data()));
        text.setUTF16String(fixtures[0].data(), fixtures[0].size() - 1);
        checkString(output, CUTF16String(fixture.data()));
        PA_Unistring* result = &output;
        text.setReturn(reinterpret_cast<sLONG_PTR*>(&result));
        checkString(output, CUTF16String(fixtures[0].data()));
        PluginBlock params = {};
        params.fResult = &result;
        PA_ReturnString(&params, const_cast<PA_Unichar*>(fixture.data()));
        checkString(output, CUTF16String(fixture.data()));
        PA_DisposeUnistring(&output);
        balanced();
    }
}

static void dispatcher()
{
    PA_Handle blob = PA_NewHandle(9);
    std::memcpy(PA_LockHandle(blob), "123456789", 9);
    PA_UnlockHandle(blob);
    BytePtr parameters[] = {reinterpret_cast<BytePtr>(&blob)};
    PA_long32 result = 0;
    PluginBlock params = {};
    params.fParameters = parameters;
    params.fResult = &result;
    PluginMain(1, &params);
    require(static_cast<PA_ulong32>(result) == 0xcbf43926, "actual dispatcher CRC remains unchanged");
    PA_DisposeHandle(blob);
    balanced();
}

int main(int argc, char** argv)
{
    require(argc == 3, "scenario and empty representation required");
    gCall4D = engine;
    allocatedEmpty = std::string(argv[2]) == "allocated";
    const std::string scenario = argv[1];
    if (scenario == "file") filePath();
    else if (scenario == "bytes") bytes();
    else if (scenario == "arrays") arrays();
    else if (scenario == "scalars") scalars();
    else if (scenario == "dispatcher") dispatcher();
    else if (scenario == "copy" || scenario == "gray" || scenario == "size" || scenario == "thumbnail")
        pictureCommands(scenario);
    else require(false, "unknown scenario");
    balanced();
    std::printf("PASS %s %s (commands=%u; strings=0 handles=0 picture-refs=0)\n",
                argv[1], argv[2], commands);
}
