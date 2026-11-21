#include "parse.h"
#include "ctype.h"
#include "utf8.h"
#include <oak/oak.h>
#include <oak/debug.h>

namespace text
{
	std::vector<std::string> split (std::string const& str, std::string const& sep)
	{
		ASSERT_LT(0, sep.size());
		std::vector<std::string> res;

		std::string::size_type bow = 0;
		while(true)
		{
			std::string::size_type eow = str.find(sep, bow);
			if(eow == std::string::npos)
			{
				res.push_back(str.substr(bow));
				break;
			}
			res.push_back(str.substr(bow, eow - bow));
			bow = eow + sep.size();
		}

		return res;
	}

	std::vector<size_t> soft_breaks (std::string const& str, size_t width, size_t tabSize, size_t prefixSize)
	{
		std::vector<size_t> res;
		auto clusterAt = [&str](size_t offset) -> std::pair<uint32_t, size_t> {
			uint32_t ch = static_cast<unsigned char>(str[offset]);
			if(ch < 0x80 && (offset + 1 == str.size() || static_cast<unsigned char>(str[offset + 1]) < 0x80))
				return { ch, 1 };
			auto cluster = diacritics::begin_of(str.data() + offset, str.data() + str.size());
			return { *cluster, static_cast<size_t>(cluster.length()) };
		};

		size_t col = 0, len = 0, spaceCol = 0, spaceLen = 0;
		while(len < str.size())
		{
			auto [ch, clusterLength] = clusterAt(len);
			size_t prevLen = len, prevCol = col;
			len += clusterLength;
			col += (ch == '\t' ? tabSize - (col % tabSize) : (ch >= 0x80 && text::is_east_asian_width(ch) ? 2 : 1));

			if(ch == '\n')
			{
				col = 0;

				spaceLen = len;
				spaceCol = col;
			}
			else if(col > width)
			{
				if(spaceCol == 0)
				{
					res.push_back(prevLen);
					width -= prefixSize;
					prefixSize = 0;
					col = col - prevCol;
				}
				else
				{
					res.push_back(spaceLen);
					width -= prefixSize;
					prefixSize = 0;
					col = col - spaceCol;
					spaceCol = 0;

					if(col > width) // Backtrack if text right of the soft break is still too wide: this can only happen for second line of indented soft wrap where the width is decreased after the first break.
					{
						auto [first, firstLength] = clusterAt(spaceLen);
						len = spaceLen + firstLength;
						col = (first == '\t' ? tabSize : 1);
					}
				}
			}
			else if(ch == ' ')
			{
				spaceLen = len;
				spaceCol = col;
			}
		}
		return res;
	}
}
